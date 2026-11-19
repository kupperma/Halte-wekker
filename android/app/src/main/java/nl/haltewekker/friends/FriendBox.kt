package nl.haltewekker.friends

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

// Friends (0.25), the iOS `FriendBox.swift`: the locked box, the only thing the relay ever holds for a friend.
//
//   box    = 0x01 ‖ ephemeral X25519 public (32) ‖ nonce (12) ‖ ChaCha20-Poly1305(inside) ‖ tag (16)
//   key    = HKDF-SHA256(X25519(eph, recipient agreeKey), salt "haltewekker-box-v1", info ephPub ‖ recipient agreeKey, 32)
//   AAD    = the recipient's account id (ASCII)
//   inside = Ed25519 signature (64) over "HWBOX1\n" + recipient account + "\n" + payload ‖ payload
//   payload = {"v":1, "k": kind, "f": sender, "t": unix s, "n": random id, "g"?: group id, "b": body}

/** What a box says. A3 reads the kinds of iOS 0.25–0.28; anything else is `Unknown` (left on the relay). */
sealed class FriendMessage {
    abstract val kind: String

    data class Request(val intro: FriendIntro) : FriendMessage() { override val kind get() = "request" }
    data class Accept(val intro: FriendIntro) : FriendMessage() { override val kind get() = "accept" }
    data object Unfriend : FriendMessage() { override val kind get() = "unfriend" }
    data class Profile(val profile: FriendProfile) : FriendMessage() { override val kind get() = "profile" }
    data class Picture(val picture: FriendPicture) : FriendMessage() { override val kind get() = "picture" }
    /** (0.26) Your trip right now: only through the state routes, never the mailbox. */
    data class Travel(val state: TravelState) : FriendMessage() { override val kind get() = "travel" }
    /** (0.27) A line in a chat (one-to-one, or in a group with `g`), or an answer to a trip card. */
    data class Message(val text: ChatText) : FriendMessage() { override val kind get() = "message" }
    data class Trip(val card: TripCard) : FriendMessage() { override val kind get() = "trip" }
    data class Seen(val seen: ChatSeen) : FriendMessage() { override val kind get() = "seen" }
    data class Group(val roster: GroupRoster) : FriendMessage() { override val kind get() = "group" }
    data class GroupPicture(val picture: FriendPicture) : FriendMessage() { override val kind get() = "gpicture" }
    data object GroupLeave : FriendMessage() { override val kind get() = "gleave" }
    /** (0.28) Your class timetable for the next two weeks (slot `tt`), or taking it back (`off`). */
    data class Timetable(val share: TimetableShare) : FriendMessage() { override val kind get() = "timetable" }
    /** (0.28) Where your trips start and your school (slot `area`): never the home address. */
    data class Area(val area: TimetableArea) : FriendMessage() { override val kind get() = "area" }
    data class Unknown(override val kind: String) : FriendMessage()

    /** Belongs to a chat (read after the rest of a batch, so a group's list in the same batch is known first). */
    val isChat: Boolean get() = this is Message || this is Trip || this is Seen

    companion object {
        /** The kinds this version reads (and acknowledges). */
        val known = setOf("request", "accept", "unfriend", "profile", "picture", "travel", "message", "trip", "seen", "group",
            "gpicture", "gleave", "timetable", "area")
        /** As iOS 0.28: raised when a release learns kinds, so the mailbox is read again from the start once. */
        const val KINDS_VERSION = 4
    }
}

@Serializable data class FriendIntro(val card: FriendCard, val name: String, val note: String? = null)
@Serializable data class FriendProfile(val name: String)
/** A square JPEG (256 px), base64url, at most 40 KB decoded. */
@Serializable data class FriendPicture(val jpeg: String) {
    val bytes: ByteArray? get() = B64u.decode(jpeg)
    companion object {
        const val MAX_BYTES = 40 * 1024
        fun of(b: ByteArray) = FriendPicture(B64u.encode(b))
    }
}
@Serializable private class NoBody

/** The payload's fields other than the body. */
@Serializable
data class BoxHeader(val v: Int, val k: String, val f: String, val t: Long, val n: String, val g: String? = null)

enum class FriendBoxError { BAD_FORMAT, CANT_OPEN, BAD_SIGNATURE, WRONG_SENDER, UNKNOWN_SENDER, NEWER_VERSION }
class FriendBoxException(val error: FriendBoxError) : Exception(error.name)

/** An opened box: who sent it (their card, checked against the signature) and what it says. */
data class OpenedBox(val header: BoxHeader, val message: FriendMessage, val sender: FriendCard)

object FriendBox {
    const val VERSION: Byte = 1
    const val PAYLOAD_VERSION = 1

    private fun body(m: FriendMessage): JsonElement {
        val j = FriendJson.json
        @Suppress("UNCHECKED_CAST")
        fun <T> e(s: KSerializer<T>, v: T): JsonElement = j.encodeToJsonElement(s, v)
        return when (m) {
            is FriendMessage.Request -> e(FriendIntro.serializer(), m.intro)
            is FriendMessage.Accept -> e(FriendIntro.serializer(), m.intro)
            is FriendMessage.Profile -> e(FriendProfile.serializer(), m.profile)
            is FriendMessage.Picture -> e(FriendPicture.serializer(), m.picture)
            is FriendMessage.GroupPicture -> e(FriendPicture.serializer(), m.picture)
            is FriendMessage.Travel -> e(TravelState.serializer(), m.state)
            is FriendMessage.Message -> e(ChatText.serializer(), m.text)
            is FriendMessage.Trip -> e(TripCard.serializer(), m.card)
            is FriendMessage.Seen -> e(ChatSeen.serializer(), m.seen)
            is FriendMessage.Group -> e(GroupRoster.serializer(), m.roster)
            is FriendMessage.Timetable -> e(TimetableShare.serializer(), m.share)
            is FriendMessage.Area -> e(TimetableArea.serializer(), m.area)
            FriendMessage.Unfriend, FriendMessage.GroupLeave, is FriendMessage.Unknown -> JsonObject(emptyMap())
        }
    }

    /** The payload's exact bytes (keys sorted, as every app writes it). `at`: unix seconds (whole). */
    fun payload(m: FriendMessage, from: String, at: Long, id: String, group: String? = null): ByteArray {
        val o = buildJsonObject {
            put("v", PAYLOAD_VERSION)
            put("k", m.kind)
            put("f", from)
            put("t", at)
            put("n", id)
            if (group != null) put("g", group)
            put("b", body(m))
        }
        return FriendJson.write(o).toByteArray(Charsets.UTF_8)
    }

    fun parse(data: ByteArray): Pair<BoxHeader, FriendMessage> {
        val root = FriendJson.parse(data) as? JsonObject ?: throw FriendBoxException(FriendBoxError.BAD_FORMAT)
        val h = FriendJson.decode(BoxHeader.serializer(), root) ?: throw FriendBoxException(FriendBoxError.BAD_FORMAT)
        if (h.v > PAYLOAD_VERSION) throw FriendBoxException(FriendBoxError.NEWER_VERSION)
        val b = root["b"]
        fun <T> need(s: KSerializer<T>): T {
            val e = b ?: throw FriendBoxException(FriendBoxError.BAD_FORMAT)
            return FriendJson.decode(s, e) ?: throw FriendBoxException(FriendBoxError.BAD_FORMAT)
        }
        fun noBody() { if (b != null && b !is JsonObject) throw FriendBoxException(FriendBoxError.BAD_FORMAT) }
        val m: FriendMessage = when (h.k) {
            "request" -> FriendMessage.Request(need(FriendIntro.serializer()).also { if (!it.card.isValid) throw FriendBoxException(FriendBoxError.BAD_FORMAT) })
            "accept" -> FriendMessage.Accept(need(FriendIntro.serializer()).also { if (!it.card.isValid) throw FriendBoxException(FriendBoxError.BAD_FORMAT) })
            "unfriend" -> { noBody(); FriendMessage.Unfriend }
            "profile" -> FriendMessage.Profile(need(FriendProfile.serializer()))
            "picture" -> FriendMessage.Picture(need(FriendPicture.serializer()).also { if (it.bytes == null) throw FriendBoxException(FriendBoxError.BAD_FORMAT) })
            "travel" -> FriendMessage.Travel(need(TravelState.serializer()))
            "message" -> FriendMessage.Message(need(ChatText.serializer()))
            "trip" -> FriendMessage.Trip(need(TripCard.serializer()))
            "seen" -> FriendMessage.Seen(need(ChatSeen.serializer()))
            "group" -> FriendMessage.Group(need(GroupRoster.serializer()))
            "gpicture" -> FriendMessage.GroupPicture(need(FriendPicture.serializer()).also { if (it.bytes == null) throw FriendBoxException(FriendBoxError.BAD_FORMAT) })
            "gleave" -> { noBody(); FriendMessage.GroupLeave }
            "timetable" -> FriendMessage.Timetable(need(TimetableShare.serializer()))
            "area" -> FriendMessage.Area(need(TimetableArea.serializer()))
            else -> FriendMessage.Unknown(h.k)
        }
        return h to m
    }

    fun signed(payload: ByteArray, to: String): ByteArray = "HWBOX1\n$to\n".toByteArray() + payload

    /** Locks `m` for the friend with `card`. */
    fun seal(m: FriendMessage, from: FriendIdentity, to: FriendCard, at: Long = System.currentTimeMillis() / 1000,
             id: String = RelaySign.nonce(), group: String? = null): ByteArray =
        seal(payload(m, from.account, at, id, group), from, to)

    /** Locks a payload already written (the test vectors pass the ephemeral key and the nonce). */
    fun seal(payload: ByteArray, from: FriendIdentity, to: FriendCard,
             eph: ByteArray = FriendCrypto.randomBytes(32), nonce: ByteArray = FriendCrypto.randomBytes(12)): ByteArray {
        val sig = from.sign(signed(payload, to.account))
        return lock(sig + payload, to, eph, nonce)
    }

    /** The box around a signed inside: no randomness of its own (checked byte for byte against the test vectors). */
    fun lock(inner: ByteArray, to: FriendCard, eph: ByteArray, nonce: ByteArray): ByteArray {
        if (!to.isValid) throw FriendBoxException(FriendBoxError.BAD_FORMAT)
        val ephPub = FriendCrypto.xPublic(eph)
        val shared = FriendCrypto.agree(eph, to.agreeKey) ?: throw FriendBoxException(FriendBoxError.BAD_FORMAT)
        val key = boxKey(shared, ephPub, to.agreeKey)
        val sealed = FriendCrypto.seal(key, nonce, inner, to.account.toByteArray())
        return byteArrayOf(VERSION) + ephPub + nonce + sealed
    }

    fun boxKey(shared: ByteArray, eph: ByteArray, recipient: ByteArray): ByteArray =
        FriendCrypto.hkdf(shared, "haltewekker-box-v1".toByteArray(), eph + recipient, 32)

    /**
     * Opens a box left for `me` by `from` (as the relay says). `known` gives a card by account; a request or an accept
     * carries its own (checked to be the sender's).
     */
    fun open(data: ByteArray, me: FriendIdentity, from: String, known: (String) -> FriendCard?): OpenedBox {
        if (data.size <= 1 + 32 + 12 + 16 + 64 || data[0] != VERSION) throw FriendBoxException(FriendBoxError.BAD_FORMAT)
        val eph = data.copyOfRange(1, 33)
        val nonce = data.copyOfRange(33, 45)
        val rest = data.copyOfRange(45, data.size)
        val shared = FriendCrypto.agree(me.agreeSecret, eph) ?: throw FriendBoxException(FriendBoxError.CANT_OPEN)
        val key = boxKey(shared, eph, me.agreeKey)
        val inner = FriendCrypto.open(key, nonce, rest, me.account.toByteArray()) ?: throw FriendBoxException(FriendBoxError.CANT_OPEN)
        if (inner.size <= 64) throw FriendBoxException(FriendBoxError.BAD_FORMAT)
        val sig = inner.copyOfRange(0, 64)
        val p = inner.copyOfRange(64, inner.size)
        val (h, m) = parse(p)
        if (h.f != from) throw FriendBoxException(FriendBoxError.WRONG_SENDER)
        val sender: FriendCard = when (m) {
            is FriendMessage.Request -> m.intro.card.also { if (it.account != from) throw FriendBoxException(FriendBoxError.WRONG_SENDER) }
            is FriendMessage.Accept -> m.intro.card.also { if (it.account != from) throw FriendBoxException(FriendBoxError.WRONG_SENDER) }
            else -> known(from) ?: throw FriendBoxException(FriendBoxError.UNKNOWN_SENDER)
        }
        if (!FriendCrypto.verify(sender.signKey, signed(p, me.account), sig)) throw FriendBoxException(FriendBoxError.BAD_SIGNATURE)
        return OpenedBox(h, m, sender)
    }
}

/** Your own backup on the relay: 0x01 ‖ nonce (12) ‖ ChaCha20-Poly1305(vault key, AAD "hw-vault-v1\n" + account) ‖ tag. */
object FriendVault {
    fun seal(plain: ByteArray, me: FriendIdentity, nonce: ByteArray = FriendCrypto.randomBytes(12)): ByteArray =
        byteArrayOf(1) + nonce + FriendCrypto.seal(me.vaultKey, nonce, plain, aad(me))

    fun open(data: ByteArray, me: FriendIdentity): ByteArray? {
        if (data.size <= 1 + 28 || data[0] != 1.toByte()) return null
        return FriendCrypto.open(me.vaultKey, data.copyOfRange(1, 13), data.copyOfRange(13, data.size), aad(me))
    }

    private fun aad(me: FriendIdentity) = "hw-vault-v1\n${me.account}".toByteArray()
}

/** Makes a JSON number primitive from a whole number (unix seconds as the payload's `t`). */
internal fun jsonNumber(v: Long): JsonPrimitive = JsonPrimitive(v)
