package nl.haltewekker.friends

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

// Friends (0.27), the iOS `FriendGroup.swift`: group chats. A group is a name, a list of members (each with their card)
// and who runs it (`admin`). The admin sends the list (`group`, `rev` one higher each time) to every member in the slot
// `gr.<id>`. Members must be the admin's friends; the list gives everyone the others' keys, so each line is locked once
// per member (fan-out). Anyone can leave (`gleave` to everyone); when the admin leaves, the first member left runs it.

@Serializable
data class GroupMember(val card: FriendCard, val name: String) { val id: String get() = card.account }

/** The body of a `group` box. */
@Serializable
data class GroupRoster(val name: String, val admin: String, val rev: Int, val members: List<GroupMember>) {
    fun has(account: String) = members.any { it.id == account }
    fun member(account: String) = members.firstOrNull { it.id == account }

    companion object {
        const val MAX_MEMBERS = 20

        /** As kept: names cleaned, each account once, the admin on it, 1–20 members. Null: not a list to take. */
        fun valid(r: GroupRoster): GroupRoster? {
            val seen = HashSet<String>()
            val members = mutableListOf<GroupMember>()
            for (m in r.members) {
                if (!m.card.isValid || !seen.add(m.id)) continue
                val n = FriendNames.clean(m.name)
                members.add(GroupMember(m.card, n.ifEmpty { "Someone" }))
            }
            if (members.isEmpty() || members.size > MAX_MEMBERS || r.admin !in seen || r.rev < 1) return null
            val name = FriendNames.clean(r.name)
            return GroupRoster(name.ifEmpty { "Group" }, r.admin, r.rev, members)
        }
    }
}

@Serializable
enum class GroupOut { @SerialName("left") LEFT, @SerialName("removed") REMOVED }

/** A group as kept (and in the vault as `{"id","roster","since","out"?}`). */
@Serializable
data class FriendGroup(val id: String, val roster: GroupRoster, val since: Double, val out: GroupOut? = null) {
    val isIn: Boolean get() = out == null
    val name: String get() = roster.name
    fun isAdmin(me: String) = isIn && roster.admin == me
    fun others(me: String) = roster.members.filter { it.id != me }
}

class GroupBook(groups: List<FriendGroup> = emptyList()) {
    var groups: List<FriendGroup> = groups
        private set

    fun copy() = GroupBook(groups)
    override fun equals(other: Any?) = other is GroupBook && other.groups == groups
    override fun hashCode() = groups.hashCode()

    /** A box to lock for one member and send (with `g` = the group's id). */
    data class Send(val to: FriendCard, val message: FriendMessage, val group: String, val slot: String?)

    sealed class News {
        data class Added(val group: String, val by: String) : News()
        data class Removed(val group: String) : News()
    }

    data class Received(var accepted: Boolean = false, val notes: MutableList<String> = mutableListOf(), var news: News? = null)

    fun group(id: String) = groups.firstOrNull { it.id == id }
    private fun index(id: String) = groups.indexOfFirst { it.id == id }.takeIf { it >= 0 }
    private fun set(i: Int, g: FriendGroup) { groups = groups.toMutableList().also { it[i] = g } }

    val current: List<FriendGroup> get() = groups.filter { it.isIn }.sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.name })
    val shown: List<FriendGroup> get() = groups.filter { it.out != GroupOut.LEFT }

    fun card(account: String): FriendCard? {
        for (g in groups) if (g.isIn) g.roster.member(account)?.let { return it.card }
        return null
    }

    fun shares(account: String) = groups.any { it.isIn && it.roster.has(account) }

    fun name(account: String): String? {
        for (g in groups) if (g.isIn) g.roster.member(account)?.let { return it.name }
        return null
    }

    fun accepts(id: String, from: String): Boolean {
        val g = group(id) ?: return false
        return g.isIn && g.roster.has(from)
    }

    // MARK: what you do

    private fun rosterSends(g: FriendGroup, me: String, extra: List<GroupMember> = emptyList()) =
        (g.others(me) + extra).map { Send(it.card, FriendMessage.Group(g.roster), g.id, rosterSlot(g.id)) }

    fun create(id: String, name: String, friends: List<Friend>, me: FriendCard, myName: String, now: Double): Pair<FriendGroup, List<Send>>? {
        val members = mutableListOf(GroupMember(me, myName.ifEmpty { "Me" }))
        for (f in friends) if (f.id != me.account && members.none { it.id == f.id }) members.add(GroupMember(f.card, f.name))
        if (members.size < 2 || members.size > GroupRoster.MAX_MEMBERS || group(id) != null) return null
        val n = FriendNames.clean(name)
        val roster = GroupRoster.valid(GroupRoster(n.ifEmpty { "Group" }, me.account, 1, members)) ?: return null
        val g = FriendGroup(id, roster, now)
        groups = groups + g
        return g to rosterSends(g, me.account)
    }

    fun add(id: String, friends: List<Friend>, me: String): List<Send> {
        val i = index(id) ?: return emptyList()
        val g = groups[i]
        if (!g.isAdmin(me)) return emptyList()
        val members = g.roster.members.toMutableList()
        for (f in friends) if (members.none { it.id == f.id } && members.size < GroupRoster.MAX_MEMBERS) members.add(GroupMember(f.card, f.name))
        if (members.size == g.roster.members.size) return emptyList()
        val ng = g.copy(roster = g.roster.copy(members = members, rev = g.roster.rev + 1))
        set(i, ng)
        return rosterSends(ng, me)
    }

    fun remove(id: String, member: String, me: String): List<Send> {
        val i = index(id) ?: return emptyList()
        val g = groups[i]
        if (!g.isAdmin(me) || member == me) return emptyList()
        val gone = g.roster.member(member) ?: return emptyList()
        val ng = g.copy(roster = g.roster.copy(members = g.roster.members.filter { it.id != member }, rev = g.roster.rev + 1))
        set(i, ng)
        return rosterSends(ng, me, listOf(gone))
    }

    fun rename(id: String, name: String, me: String): List<Send> {
        val n = FriendNames.clean(name)
        val i = index(id) ?: return emptyList()
        val g = groups[i]
        if (!g.isAdmin(me) || n.isEmpty() || n == g.roster.name) return emptyList()
        val ng = g.copy(roster = g.roster.copy(name = n, rev = g.roster.rev + 1))
        set(i, ng)
        return rosterSends(ng, me)
    }

    fun pictureSends(id: String, jpeg: ByteArray, me: String, only: Set<String>? = null): List<Send> {
        val g = group(id) ?: return emptyList()
        if (!g.isAdmin(me)) return emptyList()
        return g.others(me).filter { only?.contains(it.id) ?: true }
            .map { Send(it.card, FriendMessage.GroupPicture(FriendPicture.of(jpeg)), id, pictureSlot(id)) }
    }

    fun leave(id: String, me: String): List<Send> {
        val i = index(id) ?: return emptyList()
        val g = groups[i]
        val wasIn = g.isIn
        val others = g.others(me)
        set(i, g.copy(out = GroupOut.LEFT))
        if (!wasIn) return emptyList()
        return others.map { Send(it.card, FriendMessage.GroupLeave, id, null) }
    }

    fun forget(id: String) {
        val i = index(id) ?: return
        if (groups[i].out == GroupOut.LEFT) return
        groups = groups.filterIndexed { k, _ -> k != i }
    }

    fun refreshNames(friends: List<Friend>, me: String, myName: String): List<Send> {
        val sends = mutableListOf<Send>()
        for (i in groups.indices) {
            val g = groups[i]
            if (!g.isAdmin(me)) continue
            var changed = false
            val members = g.roster.members.map { m ->
                val want = if (m.id == me) myName.ifEmpty { null } else friends.firstOrNull { it.id == m.id }?.name
                if (want != null && want != m.name) { changed = true; m.copy(name = want) } else m
            }
            if (!changed) continue
            val ng = g.copy(roster = g.roster.copy(members = members, rev = g.roster.rev + 1))
            set(i, ng)
            sends += rosterSends(ng, me)
        }
        return sends
    }

    // MARK: what arrives

    fun receive(incoming: GroupRoster, id: String, from: String, me: String, isFriend: (String) -> Boolean, senderName: String, now: Double): Received {
        val out = Received()
        if (!isId(id)) return out
        val r = GroupRoster.valid(incoming) ?: return out
        if (!r.has(from)) return out
        val i = index(id)
        if (i == null) {
            if (r.admin != from || !isFriend(from) || !r.has(me)) return out
            groups = groups + FriendGroup(id, r, now)
            out.accepted = true
            out.notes.add("$senderName added you")
            out.news = News.Added(r.name, senderName)
            return out
        }
        val g = groups[i]
        if (g.out == GroupOut.LEFT || from != g.roster.admin || r.rev <= g.roster.rev) return out
        val who = g.roster.member(from)?.name ?: senderName
        val before = g.roster.members.map { it.id }.toSet()
        val after = r.members.map { it.id }.toSet()
        if (r.name != g.roster.name) out.notes.add("$who named the group “${r.name}”")
        for (m in r.members) if (m.id !in before && m.id != me) out.notes.add("$who added ${m.name}")
        for (m in g.roster.members) if (m.id !in after && m.id != me && m.id != from) out.notes.add("$who removed ${m.name}")
        if (r.admin != g.roster.admin) r.member(r.admin)?.let { a -> out.notes.add(if (a.id == me) "You run the group now" else "${a.name} runs the group now") }
        var ng = g.copy(roster = r)
        if (r.has(me)) {
            if (g.out == GroupOut.REMOVED) { ng = ng.copy(out = null); out.notes.add("$who added you"); out.news = News.Added(r.name, who) }
        } else if (g.out == null) {
            ng = ng.copy(out = GroupOut.REMOVED)
            out.notes.add("$who removed you")
            out.news = News.Removed(r.name)
        }
        set(i, ng)
        out.accepted = true
        return out
    }

    fun receiveLeave(id: String, from: String, me: String): String? {
        val i = index(id) ?: return null
        val g = groups[i]
        if (!g.isIn || from == me) return null
        val m = g.roster.member(from) ?: return null
        var r = g.roster.copy(members = g.roster.members.filter { it.id != from })
        var line = "${m.name} left"
        if (g.roster.admin == from) r.members.firstOrNull()?.let { next ->
            r = r.copy(admin = next.id)
            line += if (next.id == me) " · you run the group now" else " · ${next.name} runs the group now"
        }
        set(i, g.copy(roster = r))
        return line
    }

    fun acceptsPicture(id: String, from: String): Boolean {
        val g = group(id) ?: return false
        return g.isIn && g.roster.admin == from
    }

    companion object {
        fun rosterSlot(id: String) = "gr.$id"
        fun pictureSlot(id: String) = "gp.$id"
        fun seenSlot(id: String) = "se.$id"
        fun newId(): String = Hex.encode(FriendCrypto.randomBytes(12))
        fun isId(s: String) = s.length == 24 && s.all { it in '0'..'9' || it in 'a'..'f' }
    }
}
