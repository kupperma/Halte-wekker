package nl.haltewekker.friends

import kotlinx.serialization.Serializable

// Friends (0.25), the iOS `FriendBook.swift`: your friend list and what happens to it, as plain values. Each change
// gives back what to send (`Effect`); the store locks and sends those.

@Serializable
data class Friend(
    val card: FriendCard,
    val name: String,
    /** Unix seconds. */
    val since: Double,
    /** (0.26) "Show my trips": null is the default, on; kept in the vault as `"trips": false` when off. */
    val trips: Boolean? = null,
) {
    val id: String get() = card.account
    val showsTrips: Boolean get() = trips ?: true
}

@Serializable
data class FriendRequest(val card: FriendCard, val name: String, val at: Double) {
    val id: String get() = card.account
}

/** The list as kept (and in the vault as `"book"`). Mutated in place by the methods below, like the Swift struct. */
@Serializable
data class FriendBook(
    var v: Int = 1,
    var myName: String,
    var friends: List<Friend> = emptyList(),
    var incoming: List<FriendRequest> = emptyList(),
    var outgoing: List<FriendRequest> = emptyList(),
) {
    sealed class Effect {
        data class Send(val card: FriendCard, val message: FriendMessage) : Effect()
        data class Drop(val account: String) : Effect()
        data class Block(val account: String) : Effect()
    }

    enum class Added { SENT, ALREADY_FRIENDS, ACCEPTED, YOURSELF, ALREADY_ASKED }

    sealed class News {
        data class Request(val name: String) : News()
        data class Accepted(val name: String) : News()
    }

    fun snapshot() = copy()

    fun friend(id: String) = friends.firstOrNull { it.id == id }
    fun isFriend(id: String) = friend(id) != null

    fun card(id: String): FriendCard? =
        friend(id)?.card ?: incoming.firstOrNull { it.id == id }?.card ?: outgoing.firstOrNull { it.id == id }?.card

    private fun me(c: FriendCard) = FriendIntro(c, myName)

    fun add(card: FriendCard, name: String, myCard: FriendCard, now: Double): Pair<Added, List<Effect>> {
        val id = card.account
        if (id == myCard.account) return Added.YOURSELF to emptyList()
        if (isFriend(id)) return Added.ALREADY_FRIENDS to emptyList()
        incoming.firstOrNull { it.id == id }?.let { return Added.ACCEPTED to accept(it.id, myCard, now) }
        val n = FriendNames.clean(name)
        val i = outgoing.indexOfFirst { it.id == id }
        if (i >= 0) {
            val o = outgoing[i]
            outgoing = outgoing.toMutableList().also { it[i] = o.copy(card = card, name = n.ifEmpty { o.name }, at = now) }
            return Added.ALREADY_ASKED to listOf(Effect.Send(card, FriendMessage.Request(me(myCard))))
        }
        outgoing = outgoing + FriendRequest(card, n.ifEmpty { "Friend" }, now)
        return Added.SENT to listOf(Effect.Send(card, FriendMessage.Request(me(myCard))))
    }

    fun accept(id: String, myCard: FriendCard, now: Double): List<Effect> {
        val r = incoming.firstOrNull { it.id == id } ?: return emptyList()
        incoming = incoming.filter { it.id != id }
        outgoing = outgoing.filter { it.id != id }
        if (!isFriend(id)) friends = friends + Friend(r.card, r.name, now)
        return listOf(Effect.Send(r.card, FriendMessage.Accept(me(myCard))))
    }

    fun decline(id: String, block: Boolean): List<Effect> {
        if (incoming.none { it.id == id }) return emptyList()
        incoming = incoming.filter { it.id != id }
        return listOf(if (block) Effect.Block(id) else Effect.Drop(id))
    }

    fun cancel(id: String): List<Effect> {
        val r = outgoing.firstOrNull { it.id == id } ?: return emptyList()
        outgoing = outgoing.filter { it.id != id }
        return listOf(Effect.Drop(id), Effect.Send(r.card, FriendMessage.Unfriend))
    }

    fun remove(id: String): List<Effect> {
        val f = friend(id) ?: return emptyList()
        friends = friends.filter { it.id != id }
        return listOf(Effect.Drop(id), Effect.Send(f.card, FriendMessage.Unfriend))
    }

    fun showTrips(id: String, on: Boolean) {
        friends = friends.map { if (it.id == id) it.copy(trips = if (on) null else false) else it }
    }

    fun rename(name: String): List<Effect> {
        val n = FriendNames.clean(name)
        if (n.isEmpty() || n == myName) return emptyList()
        myName = n
        return friends.map { Effect.Send(it.card, FriendMessage.Profile(FriendProfile(n))) }
    }

    /** A box from `card` (opened and checked). What to send back, and what to tell you. */
    fun receive(m: FriendMessage, card: FriendCard, myCard: FriendCard, now: Double): Pair<List<Effect>, News?> {
        val id = card.account
        if (id == myCard.account) return emptyList<Effect>() to null
        when (m) {
            is FriendMessage.Request -> {
                val n = FriendNames.clean(m.intro.name)
                val fi = friends.indexOfFirst { it.id == id }
                if (fi >= 0) {
                    friends = friends.toMutableList().also { it[fi] = it[fi].copy(card = m.intro.card, name = n.ifEmpty { it[fi].name }) }
                    return listOf<Effect>(Effect.Send(m.intro.card, FriendMessage.Accept(me(myCard)))) to null
                }
                if (outgoing.any { it.id == id }) {
                    outgoing = outgoing.filter { it.id != id }
                    incoming = incoming.filter { it.id != id }
                    friends = friends + Friend(m.intro.card, n.ifEmpty { "Friend" }, now)
                    return listOf<Effect>(Effect.Send(m.intro.card, FriendMessage.Accept(me(myCard)))) to News.Accepted(n)
                }
                val ii = incoming.indexOfFirst { it.id == id }
                if (ii >= 0) {
                    incoming = incoming.toMutableList().also { it[ii] = it[ii].copy(card = m.intro.card, name = n.ifEmpty { it[ii].name }, at = now) }
                    return emptyList<Effect>() to null
                }
                incoming = incoming + FriendRequest(m.intro.card, n.ifEmpty { "Someone" }, now)
                return emptyList<Effect>() to News.Request(n.ifEmpty { "Someone" })
            }
            is FriendMessage.Accept -> {
                val n = FriendNames.clean(m.intro.name)
                val fi = friends.indexOfFirst { it.id == id }
                if (fi >= 0) {
                    friends = friends.toMutableList().also { it[fi] = it[fi].copy(card = m.intro.card, name = n.ifEmpty { it[fi].name }) }
                    return emptyList<Effect>() to null
                }
                val r = outgoing.firstOrNull { it.id == id } ?: return emptyList<Effect>() to null
                outgoing = outgoing.filter { it.id != id }
                incoming = incoming.filter { it.id != id }
                val name = n.ifEmpty { r.name }
                friends = friends + Friend(m.intro.card, name, now)
                return emptyList<Effect>() to News.Accepted(name)
            }
            FriendMessage.Unfriend -> {
                friends = friends.filter { it.id != id }
                incoming = incoming.filter { it.id != id }
                outgoing = outgoing.filter { it.id != id }
                return emptyList<Effect>() to null
            }
            is FriendMessage.Profile -> {
                val n = FriendNames.clean(m.profile.name)
                if (n.isNotEmpty()) friends = friends.map { if (it.id == id) it.copy(name = n) else it }
                return emptyList<Effect>() to null
            }
            else -> return emptyList<Effect>() to null
        }
    }

    val sortedFriends: List<Friend> get() = friends.sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.name })

    companion object {
        fun named(name: String) = FriendBook(myName = FriendNames.clean(name))
    }
}
