package nl.haltewekker.friends

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import java.io.File

/** Something to say on screen for a moment (the in-app banner; iOS `Notices`). */
data class FriendBanner(val title: String, val body: String, val chat: String? = null, val at: Long = System.nanoTime())

/** A friend code opened from a link or a scan, waiting for "Send friend request". */
data class OpenedCode(val card: FriendCard, val name: String) { val id: String get() = card.account }

/**
 * Friends (0.25–0.28), the iOS `FriendStore.swift`: your account, the friend list, the groups and the relay. The list
 * and what's waiting to be sent are kept in `files/friends/friends.json` (not in a backup); the seed and the device id
 * in `FriendSecrets` (Android Keystore). Everything that changes the state runs on one lane (one thread at a time), so
 * the rules stay those of the iOS main actor. No loop of its own: it checks the relay when the app comes to the front
 * (at most every 20 s), every 30 s while Friends is open, every 8 s while a chat is open, once a minute on a trip's
 * network tick, and at the WorkManager refresh.
 */
@OptIn(ExperimentalCoroutinesApi::class)
object FriendStore {
    val lane = Dispatchers.Default.limitedParallelism(1)
    val scope = CoroutineScope(SupervisorJob() + lane)
    fun launch(block: suspend () -> Unit) = scope.launch { try { block() } catch (_: Exception) {} }

    private lateinit var ctx: Context
    private var identity: FriendIdentity? = null
    private var device = ""
    private var state = Saved()
    private var lastAuto = 0.0
    private var lastChat = 0.0
    private var lastTick = 0.0
    private var busy = false

    val book = MutableStateFlow<FriendBook?>(null)
    val groups = MutableStateFlow(GroupBook())
    val syncing = MutableStateFlow(false)
    val offline = MutableStateFlow(false)
    val lastChecked = MutableStateFlow<Double?>(null)
    /** The account was restored on another phone: this one was signed out. */
    val movedAway = MutableStateFlow(false)
    val opened = MutableStateFlow<OpenedCode?>(null)
    val myPicture = MutableStateFlow<ByteArray?>(null)
    val pictures = MutableStateFlow<Map<String, ByteArray>>(emptyMap())
    val groupPictures = MutableStateFlow<Map<String, ByteArray>>(emptyMap())
    /** (0.26) Friends travelling now: their latest state, by account. */
    val travel = MutableStateFlow<Map<String, FriendTravelSeen>>(emptyMap())
    val travelChecked = MutableStateFlow<Double?>(null)
    val sharingWith = MutableStateFlow(0)
    val travelAnswered = MutableStateFlow(false)
    val travelPaused = MutableStateFlow(false)
    /** (0.27) Lines not seen yet (FriendChats sets it). */
    val unread = MutableStateFlow(0)
    /** Something for the in-app banner. */
    val banners = MutableSharedFlow<FriendBanner>(extraBufferCapacity = 8)
    /** (0.27) "Take this trip" wants Plan open with this. */
    val planRequest = MutableStateFlow<TripCard?>(null)

    @Serializable
    private data class Saved(
        val book: FriendBook? = null,
        val cursor: Long = 0,
        val kindsVersion: Int = 0,
        val pending: List<FriendPending> = emptyList(),
        val vaultDirty: Boolean = false,
        val travelAnswered: Boolean? = null,
        val travelPaused: Boolean? = null,
        val travelSentTo: List<String>? = null,
        val travelClearDue: Boolean? = null,
        val groups: List<FriendGroup>? = null,
        val orphans: List<RelayBox>? = null,
        val picturesTo: List<String>? = null,
        /** (A3) An iOS 0.29+ vault's `extras`, kept as it came (A4 hands it to `FriendExtrasStore` once). */
        val vaultExtras: JsonElement? = null,
    )

    fun folder(c: Context): File = File(c.filesDir, "friends").also { it.mkdirs() }
    private val file: File get() = File(folder(ctx), "friends.json")

    /** At the app's start: what's on this phone (no network). */
    fun init(c: Context) {
        if (::ctx.isInitialized) return
        ctx = c.applicationContext
        movedAway.value = ctx.getSharedPreferences("friends", Context.MODE_PRIVATE).getBoolean("movedAway", false)
        val seed = FriendSecrets.get(ctx, "seed")
        val dev = FriendSecrets.get(ctx, "device")?.toString(Charsets.UTF_8)
        val me = FriendIdentity.fromSeed(seed)
        if (me != null && dev != null) {
            identity = me
            device = dev
            state = (try { file.takeIf { it.exists() }?.readBytes() } catch (_: Exception) { null })
                ?.let { FriendJson.decode(Saved.serializer(), it) } ?: Saved()
            book.value = state.book ?: FriendBook.named("")
            travelAnswered.value = state.travelAnswered ?: false
            travelPaused.value = state.travelPaused ?: false
            groups.value = GroupBook(state.groups ?: emptyList())
            myPicture.value = readPicture("me")
            val pics = HashMap<String, ByteArray>()
            for (id in ids(book.value) + memberIds(groups.value)) readPicture(id)?.let { pics[id] = it }
            pictures.value = pics
            val gp = HashMap<String, ByteArray>()
            for (g in groups.value.groups) readPicture("g-${g.id}")?.let { gp[g.id] = it }
            groupPictures.value = gp
        }
        FriendChats.init(ctx)
        FriendTimetables.init(ctx)
        FriendExtrasStore.init(ctx)
        FriendTogetherStore.init(ctx)
        // (A5) the test friend, when there is one (its own file)
        TestFriendBot.init(ctx)
        // (A4) an iOS 0.29+ vault's switches restored by A3 were kept as they came: now they're the extras' own
        state.vaultExtras?.let { e ->
            if (FriendExtrasStore.vaultSettings == null) FriendExtrasStore.restore(FriendJson.decode(ExtrasSettings.serializer(), e))
            state = state.copy(vaultExtras = null)
            save()
        }
    }

    private fun save() {
        try {
            val tmp = File(file.parentFile, "friends.json.tmp")
            tmp.writeBytes(FriendJson.encode(Saved.serializer(), state))
            tmp.renameTo(file)
        } catch (_: Exception) {}
    }

    private fun ids(b: FriendBook?): List<String> = b?.let { it.friends.map { f -> f.id } + it.incoming.map { r -> r.id } + it.outgoing.map { r -> r.id } } ?: emptyList()
    private fun memberIds(g: GroupBook) = g.groups.filter { it.isIn }.flatMap { it.roster.members.map { m -> m.id } }

    // MARK: pictures (files/friends/pic-<account>.jpg)

    private fun pictureFile(id: String) = File(folder(ctx), "pic-$id.jpg")
    private fun readPicture(id: String): ByteArray? = try { pictureFile(id).takeIf { it.exists() }?.readBytes() } catch (_: Exception) { null }
    private fun writePicture(id: String, d: ByteArray?) {
        try { if (d != null) pictureFile(id).writeBytes(d) else pictureFile(id).delete() } catch (_: Exception) {}
    }

    // MARK: what the screens read

    val hasAccount: Boolean get() = identity != null
    val myCard: FriendCard? get() = identity?.card
    val myAccount: String? get() = identity?.account
    val backupWords: List<String>? get() = identity?.words
    val myName: String get() = book.value?.myName ?: ""
    val shareLink: String? get() = identity?.let { FriendLink.share(it.card, book.value?.myName ?: "") }
    val hasFriends: Boolean get() = book.value?.friends?.isNotEmpty() == true
    /** Requests waiting and lines not seen yet: the Friends button's badge. */
    fun badge(b: FriendBook?, unread: Int): Int = (b?.incoming?.size ?: 0) + unread

    fun name(account: String): String {
        if (account == identity?.account) return "You"
        return book.value?.friend(account)?.name ?: groups.value.name(account) ?: "Someone"
    }

    fun group(id: String): FriendGroup? = groups.value.group(id)

    // MARK: the account

    suspend fun create(name: String) = withContext(lane) {
        val me = FriendIdentity.random()
        val dev = RelaySign.newDevice()
        FriendRelay(me, dev).register()
        adopt(me, dev, FriendBook.named(name))
        state = state.copy(vaultDirty = true)
        save()
        syncNow(Why.NOW)
    }

    class BadCode : Exception("bad code")

    /** The backup code typed here: the account (and the list kept on the relay) comes here; the other phone is signed out. */
    suspend fun restore(words: List<String>, name: String): Boolean = withContext(lane) {
        val me = FriendIdentity.fromWords(words) ?: throw BadCode()
        val dev = RelaySign.newDevice()
        val relay = FriendRelay(me, dev)
        relay.register()
        val restored = try { relay.vaultGet() } catch (_: Exception) { null }
            ?.let { FriendVault.open(it, me) }?.let { FriendJson.decode(FriendVaultContents.serializer(), it) }
        adopt(me, dev, restored?.book ?: FriendBook.named(name))
        val g = GroupBook(restored?.groups ?: emptyList())
        groups.value = g
        FriendTimetables.restore(restored?.timetable)
        val pic = restored?.picture?.let { B64u.decode(it) }
        myPicture.value = pic
        writePicture("me", pic)
        FriendExtrasStore.restore(restored?.extras)
        state = state.copy(groups = g.groups, vaultDirty = restored == null)
        save()
        syncNow(Why.NOW)
        restored != null
    }

    private fun adopt(me: FriendIdentity, dev: String, b: FriendBook) {
        FriendSecrets.set(ctx, "seed", me.seed)
        FriendSecrets.set(ctx, "device", dev.toByteArray())
        identity = me
        device = dev
        state = Saved(book = b, kindsVersion = FriendMessage.KINDS_VERSION)
        book.value = b.snapshot()
        movedAway.value = false
        ctx.getSharedPreferences("friends", Context.MODE_PRIVATE).edit().remove("movedAway").apply()
        FriendWork.update(ctx)
    }

    /** Deletes the account: friends are told, the relay forgets it, this phone forgets the keys. */
    suspend fun deleteAccount() = withContext(lane) {
        val me = identity
        val b = book.value
        if (me != null && b != null) {
            val relay = FriendRelay(me, device)
            val boxes = b.friends.map { FriendPending(FriendPending.BOX, it.id, B64u.encode(FriendBox.seal(FriendMessage.Unfriend, me, it.card))) }.toMutableList()
            val g = groups.value.copy()
            for (grp in g.current) boxes += pendings(g.leave(grp.id, me.account), me)
            for (chunk in boxes.chunked(20)) try { relay.send(chunk) } catch (_: Exception) {}
            try { relay.leave() } catch (_: Exception) {}
        }
        forget(moved = false)
    }

    private fun forget(moved: Boolean) {
        // (A5) the test friend goes with your account
        TestFriendBot.userGone()
        FriendSecrets.set(ctx, "seed", null)
        FriendSecrets.set(ctx, "device", null)
        file.delete()
        for (id in pictures.value.keys + "me" + groups.value.groups.map { "g-${it.id}" }) writePicture(id, null)
        pictures.value = emptyMap(); myPicture.value = null; groupPictures.value = emptyMap()
        travel.value = emptyMap(); sharingWith.value = 0
        travelAnswered.value = false; travelPaused.value = false
        groups.value = GroupBook()
        unread.value = 0
        FriendChats.clearAll()
        FriendTimetables.forgetAll()
        FriendExtrasStore.forgetAll()
        FriendTogetherStore.forgetAll()
        identity = null
        device = ""
        state = Saved()
        book.value = null
        opened.value = null
        movedAway.value = moved
        ctx.getSharedPreferences("friends", Context.MODE_PRIVATE).edit().putBoolean("movedAway", moved).apply()
        if (moved) banners.tryEmit(FriendBanner("Friends moved to another phone", "Your friends account was restored on another phone, so this one was signed out."))
        FriendWork.update(ctx)
    }

    fun dismissMoved() {
        movedAway.value = false
        ctx.getSharedPreferences("friends", Context.MODE_PRIVATE).edit().remove("movedAway").apply()
    }

    // MARK: friends

    /** A link opened (haltewekker://friend?… or the https /add page): Friends opens with it. False: not a friend link. */
    fun handle(link: String): Boolean {
        val c = FriendLink.parse(link) ?: return link.lowercase().startsWith("haltewekker://friend")
        opened.value = OpenedCode(c.first, c.second)
        return true
    }

    suspend fun add(code: OpenedCode): FriendBook.Added? = withContext(lane) {
        val me = identity ?: return@withContext null
        val b = book.value?.snapshot() ?: return@withContext null
        val (result, effects) = b.add(code.card, code.name, me.card, now())
        apply(b, effects)
        syncNow(Why.NOW)
        result
    }

    suspend fun accept(id: String) = change { b, c -> b.accept(id, c, now()) }
    suspend fun decline(id: String, block: Boolean) = change { b, _ -> b.decline(id, block) }
    suspend fun cancel(id: String) = change { b, _ -> b.cancel(id) }
    suspend fun remove(id: String) = change { b, _ -> b.remove(id) }
    suspend fun rename(name: String) = withContext(lane) {
        val me = identity ?: return@withContext
        val b = book.value?.snapshot() ?: return@withContext
        apply(b, b.rename(name))
        refreshGroupNames()
        syncNow(Why.NOW)
    }

    private suspend fun change(f: (FriendBook, FriendCard) -> List<FriendBook.Effect>) = withContext(lane) {
        val me = identity ?: return@withContext
        val b = book.value?.snapshot() ?: return@withContext
        apply(b, f(b, me.card))
        syncNow(Why.NOW)
    }

    private fun now() = System.currentTimeMillis() / 1000.0

    /** The new list kept (and to be backed up), and what it says to send queued, in order. */
    private fun apply(b: FriendBook, effects: List<FriendBook.Effect>) {
        val me = identity ?: return
        val dirty = b != book.value
        book.value = b.snapshot()
        var pending = state.pending
        for (e in effects) {
            when (e) {
                is FriendBook.Effect.Send -> {
                    try { pending = pending + FriendPending(FriendPending.BOX, e.card.account, B64u.encode(FriendBox.seal(e.message, me, e.card))) } catch (_: Exception) {}
                    // a request or a yes brings your picture along
                    if (e.message is FriendMessage.Request || e.message is FriendMessage.Accept) myPicture.value?.let { pending = pending + picturePending(it, me, e.card) }
                }
                is FriendBook.Effect.Drop -> pending = pending + FriendPending(FriendPending.DROP, e.account)
                is FriendBook.Effect.Block -> pending = pending + FriendPending(FriendPending.BLOCK, e.account)
            }
        }
        state = state.copy(book = b.snapshot(), pending = pending, vaultDirty = state.vaultDirty || dirty)
        if (travel.value.keys.any { !b.isFriend(it) }) travel.value = travel.value.filterKeys { b.isFriend(it) }
        save()
        FriendChats.refresh()
        FriendWork.update(ctx)
    }

    private fun picturePending(jpeg: ByteArray, me: FriendIdentity, to: FriendCard) =
        FriendPending(FriendPending.BOX, to.account, B64u.encode(FriendBox.seal(FriendMessage.Picture(FriendPicture.of(jpeg)), me, to)), "picture", 30 * 86400)

    /** Your picture (cropped, 256 px, ≤ 40 KB) to every friend and the people you share a group with; null takes it away here. */
    suspend fun setPicture(jpeg: ByteArray?) = withContext(lane) {
        val me = identity ?: return@withContext
        val b = book.value ?: return@withContext
        if (jpeg != null && jpeg.size > FriendPicture.MAX_BYTES) return@withContext
        myPicture.value = jpeg
        writePicture("me", jpeg)
        state = state.copy(vaultDirty = true)
        if (jpeg != null) {
            for (f in b.friends) replacePending(picturePending(jpeg, me, f.card))
            for (c in coMemberCards(b)) replacePending(picturePending(jpeg, me, c))
        }
        save()
        syncNow(Why.NOW)
    }

    private fun keepPictures(got: Map<String, ByteArray>) {
        val p = pictures.value.toMutableMap()
        for ((id, d) in got) { p[id] = d; writePicture(id, d) }
        val live = (ids(book.value) + memberIds(groups.value)).toSet()
        for (id in p.keys.toList()) if (id !in live) { p.remove(id); writePicture(id, null) }
        pictures.value = p
    }

    // MARK: groups and lines (0.27)

    private fun coMemberCards(b: FriendBook): List<FriendCard> {
        val me = identity?.account ?: return emptyList()
        val seen = HashSet<String>()
        val out = mutableListOf<FriendCard>()
        for (g in groups.value.groups) if (g.isIn) for (m in g.roster.members) {
            if (m.id != me && !b.isFriend(m.id) && seen.add(m.id)) out.add(m.card)
        }
        return out
    }

    private fun pendings(sends: List<GroupBook.Send>, me: FriendIdentity): List<FriendPending> = sends.mapNotNull { x ->
        try { FriendPending(FriendPending.BOX, x.to.account, B64u.encode(FriendBox.seal(x.message, me, x.to, group = x.group)), x.slot) } catch (_: Exception) { null }
    }

    private fun queue(sends: List<GroupBook.Send>) {
        val me = identity ?: return
        for (p in pendings(sends, me)) replacePending(p)
    }

    /** Queued; a box for the same slot at the same person still waiting goes (only the newest matters). */
    private fun replacePending(p: FriendPending) {
        var l = state.pending
        if (p.slot != null) l = l.filter { !(it.op == FriendPending.BOX && it.to == p.to && it.slot == p.slot) }
        state = state.copy(pending = l + p)
    }

    private fun setGroups(g: GroupBook) {
        val dirty = g != groups.value
        groups.value = GroupBook(g.groups)
        state = state.copy(groups = g.groups, vaultDirty = state.vaultDirty || dirty)
        save()
    }

    private fun takeGroups(r: FriendInbox.Result) {
        setGroups(r.groups)
        if (r.groupPictures.isNotEmpty()) {
            val gp = groupPictures.value.toMutableMap()
            for ((gid, d) in r.groupPictures) {
                if (d.isEmpty()) gp.remove(gid) else gp[gid] = d
                writePicture("g-$gid", d.takeIf { it.isNotEmpty() })
            }
            groupPictures.value = gp
        }
        for (n in r.groupNews) when (n) {
            is GroupBook.News.Added -> banners.tryEmit(FriendBanner("${n.by} added you to “${n.group}”", "Open Friends to see the group."))
            is GroupBook.News.Removed -> banners.tryEmit(FriendBanner("You’re no longer in “${n.group}”", "Its chat stays to read."))
        }
        sharePictureWithGroups()
        refreshGroupNames()
        save()
    }

    private fun sharePictureWithGroups() {
        val me = identity ?: return
        val b = book.value ?: return
        val jpeg = myPicture.value ?: return
        val had = (state.picturesTo ?: emptyList()).toMutableSet()
        for (c in coMemberCards(b)) if (had.add(c.account)) replacePending(picturePending(jpeg, me, c))
        state = state.copy(picturesTo = had.sorted().ifEmpty { null })
    }

    private fun refreshGroupNames() {
        val me = identity ?: return
        val b = book.value ?: return
        val g = groups.value.copy()
        val sends = g.refreshNames(b.friends, me.account, b.myName)
        if (sends.isEmpty()) return
        setGroups(g)
        queue(sends)
        save()
    }

    suspend fun createGroup(name: String, friendIds: List<String>, picture: ByteArray?): String? = withContext(lane) {
        val me = identity ?: return@withContext null
        val b = book.value ?: return@withContext null
        val friends = friendIds.mapNotNull { b.friend(it) }
        val g = groups.value.copy()
        val id = GroupBook.newId()
        val made = g.create(id, name, friends, me.card, b.myName, now()) ?: return@withContext null
        setGroups(g)
        queue(made.second)
        FriendChats.note("You made the group", ChatKey.group(id))
        if (picture != null) setGroupPictureQueued(id, picture)
        sharePictureWithGroups()
        save()
        syncNow(Why.NOW)
        id
    }

    suspend fun addToGroup(id: String, friendIds: List<String>) = withContext(lane) {
        val me = identity ?: return@withContext
        val b = book.value ?: return@withContext
        val friends = friendIds.mapNotNull { b.friend(it) }
        val g = groups.value.copy()
        val sends = g.add(id, friends, me.account)
        if (sends.isEmpty()) return@withContext
        setGroups(g)
        queue(sends)
        for (f in friends) FriendChats.note("You added ${f.name}", ChatKey.group(id))
        groupPictures.value[id]?.let { queue(g.pictureSends(id, it, me.account, friendIds.toSet())) }
        sharePictureWithGroups()
        save()
        syncNow(Why.NOW)
    }

    suspend fun removeFromGroup(id: String, member: String) = withContext(lane) {
        val me = identity ?: return@withContext
        val who = name(member)
        val g = groups.value.copy()
        val sends = g.remove(id, member, me.account)
        if (sends.isEmpty()) return@withContext
        setGroups(g)
        queue(sends)
        FriendChats.note("You removed $who", ChatKey.group(id))
        save()
        syncNow(Why.NOW)
    }

    suspend fun renameGroup(id: String, name: String) = withContext(lane) {
        val me = identity ?: return@withContext
        val g = groups.value.copy()
        val sends = g.rename(id, name, me.account)
        if (sends.isEmpty()) return@withContext
        setGroups(g)
        queue(sends)
        FriendChats.note("You named the group “${g.group(id)?.name ?: name}”", ChatKey.group(id))
        save()
        syncNow(Why.NOW)
    }

    suspend fun setGroupPicture(id: String, jpeg: ByteArray?) = withContext(lane) {
        setGroupPictureQueued(id, jpeg ?: ByteArray(0))
        save()
        syncNow(Why.NOW)
    }

    private fun setGroupPictureQueued(id: String, jpeg: ByteArray) {
        val me = identity ?: return
        if (groups.value.group(id)?.isAdmin(me.account) != true || jpeg.size > FriendPicture.MAX_BYTES) return
        groupPictures.value = groupPictures.value.toMutableMap().also { if (jpeg.isEmpty()) it.remove(id) else it[id] = jpeg }
        writePicture("g-$id", jpeg.takeIf { it.isNotEmpty() })
        queue(groups.value.pictureSends(id, jpeg, me.account))
    }

    suspend fun leaveGroup(id: String) = withContext(lane) {
        val me = identity ?: return@withContext
        val g = groups.value.copy()
        val sends = g.leave(id, me.account)
        setGroups(g)
        queue(sends)
        FriendChats.note("You left", ChatKey.group(id))
        save()
        syncNow(Why.NOW)
    }

    suspend fun forgetGroup(id: String) = withContext(lane) {
        val g = groups.value.copy()
        g.forget(id)
        setGroups(g)
        groupPictures.value = groupPictures.value - id
        writePicture("g-$id", null)
        FriendChats.remove(ChatKey.group(id))
    }

    /** Who a line in a chat goes to: the friend, or everyone else in the group. */
    fun recipients(chat: String): List<FriendCard> {
        val me = identity?.account ?: return emptyList()
        ChatKey.groupId(chat)?.let { gid ->
            val g = groups.value.group(gid) ?: return emptyList()
            return if (g.isIn) g.others(me).map { it.card } else emptyList()
        }
        return book.value?.friend(chat)?.let { listOf(it.card) } ?: emptyList()
    }

    /** One payload (the same `n` and `t`) locked for everyone it goes to, queued. False: nobody to send it to. */
    fun queueLine(m: FriendMessage, chat: String, n: String, at: Long, line: String): Boolean {
        val me = identity ?: return false
        val cards = recipients(chat)
        if (cards.isEmpty()) return false
        val p = FriendBox.payload(m, me.account, at, n, ChatKey.groupId(chat))
        var l = state.pending
        for (c in cards) try { l = l + FriendPending(FriendPending.BOX, c.account, B64u.encode(FriendBox.seal(p, me, c)), line = line) } catch (_: Exception) {}
        state = state.copy(pending = l)
        save()
        return true
    }

    fun queueSeen(s: ChatSeen, account: String, chat: String) {
        val me = identity ?: return
        val g = ChatKey.groupId(chat)
        val card = if (g != null) groups.value.group(g)?.roster?.member(account)?.card else book.value?.friend(account)?.card
        card ?: return
        try {
            replacePending(FriendPending(FriendPending.BOX, account, B64u.encode(FriendBox.seal(FriendMessage.Seen(s), me, card, group = g)),
                g?.let { GroupBook.seenSlot(it) } ?: "seen"))
        } catch (_: Exception) { return }
        save()
    }

    // MARK: travelling now (0.26)

    val travelFriends: List<Pair<String, Boolean>> get() = book.value?.friends?.map { it.id to it.showsTrips } ?: emptyList()
    val travelConsent: Boolean? get() = if (travelAnswered.value) true else null

    fun answerTravel(show: Boolean) = launch {
        state = state.copy(travelAnswered = true, travelPaused = !show)
        travelAnswered.value = true; travelPaused.value = !show
        save()
        FriendTravelShare.settingsChanged(ctx)
    }

    fun setTravelPaused(paused: Boolean) = launch {
        state = state.copy(travelPaused = paused)
        travelPaused.value = paused
        save()
        FriendTravelShare.settingsChanged(ctx)
    }

    fun setShowTrips(id: String, on: Boolean) = launch {
        val b = book.value?.snapshot() ?: return@launch
        b.showTrips(id, on)
        apply(b, emptyList())
        FriendTravelShare.settingsChanged(ctx)
    }

    /** Puts this trip's state at each of `ids`, and takes it back from those it went to before and doesn't now. */
    suspend fun putTravel(s: TravelState, ids: List<String>) = withContext(lane) {
        val me = identity ?: return@withContext
        val b = book.value ?: return@withContext
        val relay = FriendRelay(me, device)
        val sealed = ids.mapNotNull { b.friend(it)?.card }.mapNotNull { c -> try { c.account to FriendBox.seal(FriendMessage.Travel(s), me, c) } catch (_: Exception) { null } }
        val got = mutableListOf<String>()
        try {
            for (chunk in sealed.chunked(50)) got += relay.statePut(chunk, TravelAge.TTL).filter { it.ok }.map { it.to }
            val gone = TravelShareRules.toClear(state.travelSentTo ?: emptyList(), ids)
            if (gone.isNotEmpty()) relay.stateClear(gone)
            state = state.copy(travelSentTo = ((state.travelSentTo ?: emptyList()).filter { it !in gone } + got).toSortedSet().toList(), travelClearDue = null)
            sharingWith.value = got.size
            save()
        } catch (_: FriendRelay.Failure.SignedOut) {
            forget(moved = true)
        } catch (_: Exception) {
            if (got.isNotEmpty()) { state = state.copy(travelSentTo = ((state.travelSentTo ?: emptyList()) + got).toSortedSet().toList()); save() }
        }
    }

    suspend fun clearTravel() = withContext(lane) {
        sharingWith.value = 0
        val me = identity ?: return@withContext
        if ((state.travelSentTo ?: emptyList()).isEmpty() && state.travelClearDue != true) return@withContext
        state = try {
            FriendRelay(me, device).stateClear(null)
            state.copy(travelSentTo = null, travelClearDue = null)
        } catch (_: Exception) { state.copy(travelClearDue = true) }
        save()
    }

    suspend fun fetchTravel() = withContext(lane) {
        val me = identity ?: return@withContext
        travelRead(FriendRelay(me, device))
    }

    private suspend fun travelRead(relay: FriendRelay) {
        val b = book.value
        if (b == null || b.friends.isEmpty()) { travel.value = emptyMap(); return }
        val states = try { relay.stateGet() } catch (_: Exception) { return }
        val me = identity ?: return
        travel.value = FriendInbox.readStates(states, b, me, now())
        travelChecked.value = now()
    }

    private suspend fun travelAfterSync(relay: FriendRelay) {
        if (state.travelClearDue == true && !FriendTravelShare.sharing) {
            try {
                relay.stateClear(null)
                state = state.copy(travelSentTo = null, travelClearDue = null)
                save()
            } catch (_: Exception) {}
        }
        travelRead(relay)
    }

    fun travelling(now: Double = now()): List<FriendTravelSeen> =
        travel.value.values.filter { TravelAge.freshness(it, now) != TravelFreshness.GONE && book.value?.isFriend(it.from) == true }.sortedByDescending { it.sent }

    // MARK: timetables (0.28)

    fun timetableSettingsChanged() = launch {
        state = state.copy(vaultDirty = true)
        save()
        syncNow(Why.NOW)
    }

    private fun timetableGroupMembers(b: FriendBook, on: Set<String>): List<String> =
        groups.value.groups.filter { it.isIn && it.id in on }.flatMap { g -> g.roster.members.map { it.id } }.filter { !b.isFriend(it) }

    internal fun anyCard(id: String): FriendCard? = book.value?.friend(id)?.card ?: groups.value.card(id)

    val timetableRecipients: List<String>
        get() {
            val me = identity?.account ?: return emptyList()
            val b = book.value ?: return emptyList()
            val tt = FriendTimetables
            return TimetableShareRules.recipients(b.friends.map { it.id }, tt.off.value, timetableGroupMembers(b, tt.groupsOn.value), me,
                tt.answered.value && tt.on.value)
        }

    private suspend fun timetableDue(me: FriendIdentity, now: Double) {
        val b = book.value ?: return
        val tt = FriendTimetables
        tt.keep((b.friends.map { it.id } + memberIds(groups.value)).toSet())
        val recipients = timetableRecipients
        var sent = tt.sent
        var areaSent = tt.areaSent
        var changed = false
        val gone = TimetableShareRules.takeBack(sent, recipients)
        if (gone.isNotEmpty()) {
            for (id in gone) {
                val c = anyCard(id) ?: continue
                try {
                    replacePending(FriendPending(FriendPending.BOX, id, B64u.encode(FriendBox.seal(FriendMessage.Timetable(TimetableShare.takenBack(now)), me, c)),
                        TimetableShareRules.TIMETABLE_SLOT, TimetableShareRules.TIMETABLE_TTL))
                } catch (_: Exception) {}
            }
            sent = TimetableShareRules.afterTakeBack(sent, gone)
            areaSent = TimetableShareRules.afterTakeBack(areaSent, gone)
            changed = true
        }
        val had = (sent?.to ?: emptyList()).toSet()
        val fresh = recipients.any { it !in had }
        if (recipients.isNotEmpty() && tt.lookDue(now, fresh)) {
            val (share, area) = tt.readMine(ctx, now, sharing = true)
            if (share != null) {
                val hash = TimetableShareRules.fingerprint(FriendJson.encode(TimetableShare.serializer(), share))
                val due = TimetableShareRules.due(sent, hash, recipients, now)
                for (id in due) {
                    val c = anyCard(id) ?: continue
                    try {
                        replacePending(FriendPending(FriendPending.BOX, id, B64u.encode(FriendBox.seal(FriendMessage.Timetable(share), me, c)),
                            TimetableShareRules.TIMETABLE_SLOT, TimetableShareRules.TIMETABLE_TTL))
                    } catch (_: Exception) {}
                }
                if (due.isNotEmpty()) { sent = TimetableShareRules.after(sent, hash, due, recipients, now); changed = true }
            }
            if (area != null) {
                val hash = TimetableShareRules.fingerprint(FriendJson.encode(TimetableArea.serializer(), area))
                val due = TimetableShareRules.due(areaSent, hash, recipients, now, TimetableShareRules.AREA_REFRESH)
                for (id in due) {
                    val c = anyCard(id) ?: continue
                    try {
                        replacePending(FriendPending(FriendPending.BOX, id, B64u.encode(FriendBox.seal(FriendMessage.Area(area), me, c)),
                            TimetableShareRules.AREA_SLOT, TimetableShareRules.AREA_TTL))
                    } catch (_: Exception) {}
                }
                if (due.isNotEmpty()) { areaSent = TimetableShareRules.after(areaSent, hash, due, recipients, now); changed = true }
            }
        }
        if (changed) {
            tt.didSend(sent, areaSent)
            save()
        }
    }

    // MARK: the extras (0.29/0.30)

    /**
     * Locks one payload for each of these people (a friend, or someone in a group with you; the group's id as `g`) and
     * queues it in `slot` (a box still waiting there for them goes: only the newest matters).
     */
    fun queueBox(m: FriendMessage, ids: List<String>, slot: String, ttl: Int, group: String? = null) {
        val me = identity ?: return
        if (ids.isEmpty()) return
        val p = FriendBox.payload(m, me.account, now().toLong(), RelaySign.nonce(), group)
        for (id in ids) {
            if (id == me.account) continue
            val c = anyCard(id) ?: continue
            try { replacePending(FriendPending(FriendPending.BOX, id, B64u.encode(FriendBox.seal(p, me, c)), slot, ttl)) } catch (_: Exception) {}
        }
        save()
    }

    /** An extras switch changed: the vault keeps it, and what's shared follows at once. */
    fun extrasSettingsChanged() = launch {
        state = state.copy(vaultDirty = true)
        save()
        syncNow(Why.NOW)
    }

    // MARK: checking the relay

    enum class Why { NOW, SCREEN, AUTO, CHAT, TICK }

    /** Sends what's waiting, reads the mailbox, backs up the list if it changed (one check at a time). */
    fun sync(why: Why) = launch { syncNow(why) }

    suspend fun syncAndWait(why: Why) = withContext(lane) { syncNow(why) }

    private suspend fun syncNow(why: Why) {
        val me = identity ?: return
        if (busy) return
        val now = now()
        when (why) {
            Why.AUTO -> { if (now - lastAuto <= 20) return; lastAuto = now }
            Why.CHAT -> { if (now - lastChat < 6) return; lastChat = now }
            Why.TICK -> { if (now - lastTick < 55) return; lastTick = now }
            Why.NOW, Why.SCREEN -> {}
        }
        busy = true
        syncing.value = true
        val relay = FriendRelay(me, device)
        try {
            flush(relay)
            // (A5) the test friend's brain: right after your boxes went, so its answers come back in this same check
            TestFriendBot.check()
            if (state.kindsVersion < FriendMessage.KINDS_VERSION) state = state.copy(cursor = 0, kindsVersion = FriendMessage.KINDS_VERSION)
            var retry = state.orphans ?: emptyList()
            var orphans = emptyList<RelayBox>()
            for (round in 0 until 5) {
                val inbox = relay.inbox(state.cursor)
                val b = book.value ?: return
                val r = FriendInbox.process(inbox.boxes, b, groups.value, retry, me, now())
                retry = emptyList()
                orphans = orphans + r.orphans
                state = state.copy(orphans = orphans.takeLast(FriendInbox.MAX_ORPHANS).ifEmpty { null })
                apply(r.book, r.effects)
                takeGroups(r)
                keepPictures(r.pictures)
                for (n in r.news) { val t = FriendInbox.banner(n); banners.tryEmit(FriendBanner(t.first, t.second)); FriendChats.notifyNews(ctx, t.first, t.second) }
                FriendChats.take(ctx, r.chat)
                FriendTimetables.take(r)
                FriendExtrasStore.take(r)
                FriendTogetherStore.take(r)
                state = state.copy(cursor = inbox.cursor)
                save()
                relay.ack(r.ack)
                if (!inbox.more) break
            }
            timetableDue(me, now())
            // (0.29) the extras: a wait on its way, at school, your plan for the wake-up buddy, delays on shared rides
            FriendExtrasStore.due(now())
            // (0.30) part B: your scores for the leaderboard with friends, free time together today
            FriendTogetherStore.due(now())
            flush(relay)
            val statesDue = why != Why.CHAT || (travelChecked.value?.let { now - it >= 30 } ?: true)
            if (statesDue) travelAfterSync(relay)
            val b = book.value
            if (state.vaultDirty && b != null) {
                val s = FriendTimetables.settings
                // (A5) never the test friend: it's not in your backup
                val plain = FriendJson.encode(FriendVaultContents.serializer(), TestFriendBot.scrubbed(FriendVaultContents(book = b, picture = myPicture.value?.let { B64u.encode(it) },
                    groups = groups.value.groups.ifEmpty { null }, timetable = if (s == TimetableSettings()) null else s, extras = FriendExtrasStore.vaultSettings)))
                relay.vaultPut(FriendVault.seal(plain, me))
                state = state.copy(vaultDirty = false)
                save()
            }
            offline.value = false
            lastChecked.value = now()
            FriendChats.refresh()
        } catch (_: FriendRelay.Failure.SignedOut) {
            forget(moved = true)
        } catch (_: FriendRelay.Failure.UnknownAccount) {
            // the relay lost it (or it was idle for over a year): made again with the same keys
            try { relay.register() } catch (_: Exception) {}
        } catch (_: Exception) {
            offline.value = true
        } finally {
            busy = false
            syncing.value = false
        }
    }

    /** Sends what's waiting, oldest first; stops at the first network failure. A box refused for good is let go. */
    private suspend fun flush(relay: FriendRelay) {
        while (true) {
            val first = state.pending.firstOrNull() ?: return
            val run: List<FriendPending> = if (first.op == FriendPending.BOX) state.pending.takeWhile { it.op == FriendPending.BOX }.take(20) else listOf(first)
            try {
                when (first.op) {
                    FriendPending.DROP -> relay.drop(first.to)
                    FriendPending.BLOCK -> relay.block(first.to)
                    else -> {
                        relay.send(run)
                        val lines = run.mapNotNull { it.line }.toSet()
                        if (lines.isNotEmpty()) FriendChats.markSent(lines)
                    }
                }
            } catch (_: FriendRelay.Failure.Refused) {
                state = state.copy(pending = state.pending.filter { it !== first })
                save()
                continue
            }
            // (only what went: anything queued or replaced meanwhile stays as it is)
            state = state.copy(pending = state.pending.filter { p -> run.none { it === p } })
            save()
        }
    }
}
