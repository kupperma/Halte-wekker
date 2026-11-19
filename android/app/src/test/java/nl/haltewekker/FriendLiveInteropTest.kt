package nl.haltewekker

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import nl.haltewekker.friends.B64u
import nl.haltewekker.friends.ChatText
import nl.haltewekker.friends.FriendBook
import nl.haltewekker.friends.FriendBox
import nl.haltewekker.friends.FriendCard
import nl.haltewekker.friends.FriendIdentity
import nl.haltewekker.friends.FriendInbox
import nl.haltewekker.friends.FriendJson
import nl.haltewekker.friends.FriendMessage
import nl.haltewekker.friends.FriendPending
import nl.haltewekker.friends.FriendRelay
import nl.haltewekker.friends.FriendVault
import nl.haltewekker.friends.Hex
import nl.haltewekker.friends.TravelState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.math.BigInteger
import java.net.URI
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.Signature
import java.security.interfaces.EdECPublicKey
import java.security.interfaces.XECPublicKey
import java.security.spec.NamedParameterSpec
import java.security.spec.XECPrivateKeySpec
import java.security.spec.XECPublicKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * The live check against https://haltewekker-relay.tsfaw1.workers.dev (skipped unless HW_LIVE_RELAY=1): an account made
 * by the Android code (Bouncy Castle, FriendBox, FriendRelay, FriendInbox) and an "iOS-style" one written here from the
 * spec alone with the JDK's own crypto (SunEC Ed25519/X25519, the JDK's ChaCha20-Poly1305, HMAC HKDF; none of the app's
 * code), exchange a request, an accept, a chat line and a travel state through the relay, then both leave.
 *
 *   HW_LIVE_RELAY=1 ./gradlew testReleaseUnitTest --tests nl.haltewekker.FriendLiveInteropTest
 */
class FriendLiveInteropTest {
    private val base = System.getenv("HW_RELAY_URL") ?: FriendRelay.BASE

    /** The other phone, from the spec: seed → HKDF → Ed25519 / X25519; boxes; signed requests. */
    class IosStyle(private val base: String) {
        val seed = ByteArray(16).also { SecureRandom().nextBytes(it) }
        private fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray): ByteArray {
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(SecretKeySpec(salt, "HmacSHA256"))
            val prk = mac.doFinal(ikm)
            mac.init(SecretKeySpec(prk, "HmacSHA256"))
            mac.update(info); mac.update(1)
            return mac.doFinal().copyOf(32)
        }
        private fun sha(vararg b: ByteArray) = MessageDigest.getInstance("SHA-256").run { b.forEach { update(it) }; digest() }
        private fun le(n: BigInteger): ByteArray {
            val be = n.toByteArray().dropWhile { it == 0.toByte() }.toByteArray()
            return ByteArray(32) { i -> if (i < be.size) be[be.size - 1 - i] else 0 }
        }

        private val signSeed = hkdf(seed, "haltewekker-seed-v1".toByteArray(), "sign".toByteArray())
        private val agreePriv = hkdf(seed, "haltewekker-seed-v1".toByteArray(), "agree".toByteArray())
        private val edPair = KeyPairGenerator.getInstance("Ed25519").apply {
            initialize(NamedParameterSpec.ED25519, object : SecureRandom() { override fun nextBytes(b: ByteArray) { signSeed.copyInto(b) } })
        }.generateKeyPair()
        val signKey: ByteArray = (edPair.public as EdECPublicKey).point.let { p ->
            val b = le(p.y); if (p.isXOdd) b[31] = (b[31].toInt() or 0x80).toByte(); b
        }
        private fun x25519(priv: ByteArray, pub: ByteArray): ByteArray {
            val kf = KeyFactory.getInstance("X25519")
            val ka = KeyAgreement.getInstance("X25519")
            ka.init(kf.generatePrivate(XECPrivateKeySpec(NamedParameterSpec.X25519, priv)))
            val u = BigInteger(1, pub.reversedArray().also { it[0] = (it[0].toInt() and 0x7f).toByte() })
            ka.doPhase(kf.generatePublic(XECPublicKeySpec(NamedParameterSpec.X25519, u)), true)
            return ka.generateSecret()
        }
        val agreeKey: ByteArray = x25519(agreePriv, ByteArray(32).also { it[0] = 9 })
        val account: String = sha("haltewekker-account-v1".toByteArray(), signKey).copyOf(16).joinToString("") { "%02x".format(it) }
        val device: String = ByteArray(16).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it) }
        val cardJson get() = """{"a":"${B64u.encode(agreeKey)}","s":"${B64u.encode(signKey)}"}"""

        fun sign(msg: ByteArray): ByteArray = Signature.getInstance("Ed25519").run { initSign(edPair.private); update(msg); sign() }
        fun verify(pub: ByteArray, msg: ByteArray, sig: ByteArray): Boolean {
            val y = le(BigInteger.ZERO).let { pub.copyOf() }
            val xOdd = (y[31].toInt() and 0x80) != 0
            y[31] = (y[31].toInt() and 0x7f).toByte()
            val point = java.security.spec.EdECPoint(xOdd, BigInteger(1, y.reversedArray()))
            val key = KeyFactory.getInstance("Ed25519").generatePublic(java.security.spec.EdECPublicKeySpec(NamedParameterSpec.ED25519, point))
            return Signature.getInstance("Ed25519").run { initVerify(key); update(msg); verify(sig) }
        }

        private fun chacha(encrypt: Boolean, key: ByteArray, nonce: ByteArray, data: ByteArray, aad: ByteArray): ByteArray {
            val c = Cipher.getInstance("ChaCha20-Poly1305")
            c.init(if (encrypt) Cipher.ENCRYPT_MODE else Cipher.DECRYPT_MODE, SecretKeySpec(key, "ChaCha20"), IvParameterSpec(nonce))
            c.updateAAD(aad)
            return c.doFinal(data)
        }

        /** A box for `to` (its account and agreeKey), signed by this account. */
        fun seal(payload: String, toAccount: String, toAgree: ByteArray): ByteArray {
            val p = payload.toByteArray()
            val sig = sign("HWBOX1\n$toAccount\n".toByteArray() + p)
            val eph = ByteArray(32).also { SecureRandom().nextBytes(it) }
            val ephPub = x25519(eph, ByteArray(32).also { it[0] = 9 })
            val key = hkdf(x25519(eph, toAgree), "haltewekker-box-v1".toByteArray(), ephPub + toAgree)
            val nonce = ByteArray(12).also { SecureRandom().nextBytes(it) }
            return byteArrayOf(1) + ephPub + nonce + chacha(true, key, nonce, sig + p, toAccount.toByteArray())
        }

        /** Opens a box for this account; checks the signature with `signer` (or the card inside a request/accept). */
        fun open(box: ByteArray, signer: ByteArray?): JsonObject {
            require(box[0] == 1.toByte())
            val eph = box.copyOfRange(1, 33)
            val key = hkdf(x25519(agreePriv, eph), "haltewekker-box-v1".toByteArray(), eph + agreeKey)
            val inner = chacha(false, key, box.copyOfRange(33, 45), box.copyOfRange(45, box.size), account.toByteArray())
            val sig = inner.copyOfRange(0, 64)
            val p = inner.copyOfRange(64, inner.size)
            val o = Json.parseToJsonElement(String(p)).jsonObject
            val pub = signer ?: B64u.decode(o["b"]!!.jsonObject["card"]!!.jsonObject["s"]!!.jsonPrimitive.content)!!
            check(verify(pub, "HWBOX1\n$account\n".toByteArray() + p, sig)) { "bad signature" }
            return o
        }

        fun call(path: String, body: String): Pair<Int, JsonObject?> {
            val b = body.toByteArray()
            val t = System.currentTimeMillis() / 1000
            val nonce = B64u.encode(ByteArray(16).also { SecureRandom().nextBytes(it) })
            val canon = listOf("HW1", "POST", path, account, device, "$t", nonce, sha(b).joinToString("") { "%02x".format(it) }).joinToString("\n")
            val c = URI(base + path).toURL().openConnection() as java.net.HttpURLConnection
            c.requestMethod = "POST"
            c.doOutput = true
            for ((k, v) in listOf("Content-Type" to "application/json", "X-HW-Account" to account, "X-HW-Device" to device, "X-HW-Time" to "$t",
                    "X-HW-Nonce" to nonce, "X-HW-Signature" to B64u.encode(sign(canon.toByteArray())), "User-Agent" to "Haltewekker-interop-check")) {
                c.setRequestProperty(k, v)
            }
            c.outputStream.use { it.write(b) }
            val code = c.responseCode
            val text = (if (code < 400) c.inputStream else c.errorStream)?.use { String(it.readBytes()) } ?: ""
            return code to (try { Json.parseToJsonElement(text).jsonObject } catch (_: Exception) { null })
        }
    }

    @Test fun androidAndIosStyleTalkThroughTheLiveRelay() = runBlocking {
        assumeTrue("set HW_LIVE_RELAY=1 to run against the live relay", System.getenv("HW_LIVE_RELAY") == "1")
        val ios = IosStyle(base)
        val me = FriendIdentity.random()
        val relay = FriendRelay(me, nl.haltewekker.friends.RelaySign.newDevice(), base, "Haltewekker-interop-check")
        try {
            // both register (the iOS-style account id comes from its own sums: the Android code must agree)
            assertTrue(relay.register().created)
            val (st, reg) = ios.call("/f/v1/register", """{"signKey":"${B64u.encode(ios.signKey)}"}""")
            assertEquals(200, st); assertEquals(ios.account, reg!!["account"]!!.jsonPrimitive.content)
            val iosCard = FriendCard.of(ios.signKey, ios.agreeKey)!!
            assertEquals(ios.account, iosCard.account)

            // Android: a friend request to the iOS-style account
            var book = FriendBook.named("Andi")
            val (_, effects) = book.add(iosCard, "Ivy", me.card, System.currentTimeMillis() / 1000.0)
            val req = effects.filterIsInstance<FriendBook.Effect.Send>().single()
            val sent = relay.send(listOf(FriendPending(FriendPending.BOX, ios.account, B64u.encode(FriendBox.seal(req.message, me, req.card)))))
            assertTrue(sent.single().ok)

            // iOS-style: reads its mailbox, opens the request by the spec, checks who it's from
            val (_, inbox) = ios.call("/f/v1/inbox", """{"after":0,"limit":100}""")
            val box = inbox!!["boxes"]!!.jsonArray.single().jsonObject
            assertEquals(me.account, box["from"]!!.jsonPrimitive.content)
            val opened = ios.open(B64u.decode(box["data"]!!.jsonPrimitive.content)!!, null)
            assertEquals("request", opened["k"]!!.jsonPrimitive.content)
            assertEquals("Andi", opened["b"]!!.jsonObject["name"]!!.jsonPrimitive.content)
            assertEquals(me.account, opened["f"]!!.jsonPrimitive.content)
            ios.call("/f/v1/ack", """{"ids":[${box["id"]!!.jsonPrimitive.long}]}""")

            // iOS-style: says yes and writes a line (its own JSON, its own crypto)
            val t = System.currentTimeMillis() / 1000
            val accept = """{"b":{"card":${ios.cardJson},"name":"Ivy"},"f":"${ios.account}","k":"accept","n":"interop-1","t":$t,"v":1}"""
            val line = """{"b":{"text":"On the 305 ’"},"f":"${ios.account}","k":"message","n":"interop-2","t":$t,"v":1}"""
            val boxes = listOf(accept, line).joinToString(",") { """{"data":"${B64u.encode(ios.seal(it, me.account, me.agreeKey))}","to":"${me.account}"}""" }
            val (s2, r2) = ios.call("/f/v1/send", """{"boxes":[$boxes]}""")
            assertEquals(200, s2); assertTrue(r2!!["results"]!!.jsonArray.all { it.jsonObject["ok"]!!.jsonPrimitive.content == "true" })

            // Android: reads them with FriendInbox (the accept first makes them friends, then the line is let in)
            val got = relay.inbox(0)
            val r = FriendInbox.process(got.boxes, book, me = me, now = System.currentTimeMillis() / 1000.0)
            book = r.book
            assertTrue(book.isFriend(ios.account))
            assertEquals("Ivy", book.friend(ios.account)!!.name)
            assertEquals(listOf("On the 305 ’"), r.chat.mapNotNull { it.line?.text?.text })
            assertEquals(2, r.ack.size)
            relay.ack(r.ack)

            // Android: its trip right now through the state routes; the iOS-style side reads and opens it
            val travel = TravelState(state = "riding", mode = "train", line = "IC", num = "3512", from = TravelState.Spot("Eindhoven Centraal", 51.44306, 5.47917),
                to = TravelState.Spot("Breda", 51.59556, 4.78), eta = (t + 1800).toDouble())
            val put = relay.statePut(listOf(ios.account to FriendBox.seal(FriendMessage.Travel(travel), me, iosCard)), 360)
            assertTrue(put.single().ok)
            val (_, states) = ios.call("/f/v1/state/get", "{}")
            val state = states!!["states"]!!.jsonArray.single().jsonObject
            val tb = ios.open(B64u.decode(state["data"]!!.jsonPrimitive.content)!!, me.signKey)
            assertEquals("travel", tb["k"]!!.jsonPrimitive.content)
            assertEquals("3512", tb["b"]!!.jsonObject["num"]!!.jsonPrimitive.content)
            assertTrue(relay.stateClear(null) >= 1)

            // iOS-style leaves a state for Android: Android's readStates opens it
            val itsTravel = """{"b":{"from":{"name":"Home"},"line":"305","mode":"bus","state":"waiting","to":{"lat":51.4401,"lon":5.4789,"name":"Eindhoven, Station"}},"f":"${ios.account}","k":"travel","n":"interop-3","t":$t,"v":1}"""
            ios.call("/f/v1/state/put", """{"states":[{"data":"${B64u.encode(ios.seal(itsTravel, me.account, me.agreeKey))}","to":"${me.account}","ttl":120}]}""")
            val seen = FriendInbox.readStates(relay.stateGet(), book, me, System.currentTimeMillis() / 1000.0)
            assertEquals("Waiting for bus 305 at Home", nl.haltewekker.friends.TravelWords.summary(seen.getValue(ios.account).state))

            // Android's vault round trip
            val plain = FriendJson.encode(nl.haltewekker.friends.FriendVaultContents.serializer(), nl.haltewekker.friends.FriendVaultContents(book = book))
            relay.vaultPut(FriendVault.seal(plain, me))
            val back = FriendVault.open(relay.vaultGet()!!, me)
            assertNotNull(back)
            assertEquals("Ivy", FriendJson.decode(nl.haltewekker.friends.FriendVaultContents.serializer(), back!!)!!.book.friends.single().name)
            println("live interop ok: android ${me.account} <-> ios-style ${ios.account} via $base")
        } finally {
            try { relay.leave() } catch (_: Exception) {}
            try { ios.call("/f/v1/leave", "{}") } catch (_: Exception) {}
        }
        Unit
    }
}
