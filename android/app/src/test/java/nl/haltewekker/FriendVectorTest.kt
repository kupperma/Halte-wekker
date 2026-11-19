package nl.haltewekker

import kotlinx.serialization.json.JsonObject
import nl.haltewekker.friends.B64u
import nl.haltewekker.friends.FriendBox
import nl.haltewekker.friends.FriendCard
import nl.haltewekker.friends.FriendCrypto
import nl.haltewekker.friends.FriendIdentity
import nl.haltewekker.friends.FriendIntro
import nl.haltewekker.friends.FriendJson
import nl.haltewekker.friends.FriendMessage
import nl.haltewekker.friends.FriendRelay
import nl.haltewekker.friends.FriendVault
import nl.haltewekker.friends.FriendVaultContents
import nl.haltewekker.friends.FriendWords
import nl.haltewekker.friends.Hex
import nl.haltewekker.friends.RelaySign
import nl.haltewekker.friends.TripAnswer
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Every test vector in docs/superpowers/specs/2026-11-18-friends-design.md (As built 0.25–0.30), made with Node's crypto
 * from the spec and checked by the iOS app's FriendVectorTests, FriendTravelVectorTests, FriendChatVectorTests,
 * FriendTimetableTests and FriendExtrasVectorTests: the same numbers here are the interop guarantee.
 * For the kinds A3 knows (0.25–0.28) the payload is also rebuilt from the parsed box and must come out byte for byte.
 */
class FriendVectorTest {
    private fun hex(s: String) = Hex.decode(s)!!
    private val sam = FriendIdentity(hex("000102030405060708090a0b0c0d0e0f"))
    private val lou = FriendIdentity(hex("101112131415161718191a1b1c1d1e1f"))
    private val kim = FriendIdentity(hex("202122232425262728292a2b2c2d2e2f"))
    private val cards = listOf(sam, lou, kim).associate { it.account to it.card }

    class V(val from: FriendIdentity, val to: FriendIdentity, val payload: String, val sig: String?, val eph: String?, val ephPub: String?,
            val nonce: String?, val key: String?, val box: String?)

    private val vectors: List<V> get() = listOf(
        V(sam, lou, """{"b":{"card":{"a":"4BkenPteSyzMhZGAEzxCVDtPbsYAfktcUGCFY_f6wTQ","s":"Pimf5pXMDZx03fVhlCwafY9i6il4P1yqNBRkQCW0IMI"},"name":"Sam"},"f":"3c157621a97cf055f5804a9826c6d1e1","k":"request","n":"vector-1","t":1800000000,"v":1}""", sig = """u7Zi2kaNq4eocGLTn5-8SvBDPzZpGq5HGqBOkGUVcvp7CdJWlP4ErXRiHUwz_a2QR8WyOHLWD-q2c0ASirOVDw""", eph = """202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f""", ephPub = """358072d6365880d1aeea329adf9121383851ed21a28e3b75e965d0d2cd166254""", nonce = """404142434445464748494a4b""", key = """391a5671a72c601c6dd34c849fc36070762b75c4199b0c4b7181414b6f3b4c8f""", box = """ATWActY2WIDRruoymt-RITg4Ue0hoo47dell0NLNFmJUQEFCQ0RFRkdISUpLhNjroAbjjIoeYOMe5kdazUPO6vUbw6CWi8bBVyPDycUHH100hP5LwyHNKs7M9kvkxy5hOoexAJL6GOvZ9Oi1kVwqOxYRggbgy-5ifJcMbXtaSibw7_JrtYzH1z5XYVbg3qcSmAAdHPDaeO01RZ4vBuq5t8w1bTo7Uaj1oh4xKD1WA1dPJ1VJJNELVrkBVcAbnYjQvG7p7x7x5uIYeGGvGPc-d5Ut9FdPapHC3Xp1lcrVPHA1F29V5tfYLzkOeQbGknEvQp6BCs150iuFeRBoI9x5WqtARgmWuN2de5qaKISfCyOpu-4knj48qm1aviXL97LBUkjJgLQ3d98wnug_TFK4O05Ns9nS8Ss6gJYLL5IT4tcPTiQOvf8Yw_5frIVF3-c187FoofV24Q"""),
        V(sam, lou, """{"b":{"coach":{"at":"EHV","front":true,"n":3,"of":6},"end":1800004200,"eta":1800003780,"from":{"lat":51.44306,"lon":5.47917,"name":"Eindhoven Centraal"},"leg":2,"legs":2,"line":"IC","mode":"train","num":"3512","pos":{"acc":12,"at":1799999990,"lat":51.5112,"lon":5.2874},"state":"riding","to":{"lat":51.59556,"lon":4.78,"name":"Breda"},"trip":"vector-trip-3512"},"f":"3c157621a97cf055f5804a9826c6d1e1","k":"travel","n":"vector-2","t":1800000000,"v":1}""", sig = """7PkPXX1XZcPuaJGBWjjmWJhPZv2Z8FlixA7Ddq0nx8x0mU2Gy6q90ZPGYeE7TaryRZL9mhCFNzpPBlSHfhilCw""", eph = """606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f""", ephPub = """675dd574ed7789310b3d2e7681f3790b466c773b1521fecf36577958371ea52f""", nonce = """808182838485868788898a8b""", key = """05c9590bb92a41d682e8ac3bf021bf56cf37208db21837c8f04264fb85e4da5c""", box = """AWdd1XTtd4kxCz0udoHzeQtGbHc7FSH-zzZXeVg3HqUvgIGCg4SFhoeIiYqLZXWLBco9z3tfobhx5IFO49FI_IR1QXGidybz-bpO_guAfOgz4G8oLdQIaF5b0bBOaJAf1w41CGfhpE6u9ABuv3dyd--Hzvkjf8lvET3kp0QXZpaPiGlZG04GLRL7cXaLgoA0WoWBO7mYef611woIfWFo_o2GXLiK8YxMongc9PQd2FIQGmhHo-xyrnK2Vy3FMYRJCpwIVDZFO5rLrLrMqzc278Q2jy7rdH468tESk0304xKQXctnPMSHZ2TDfx4TPlyErsc9DpqkRgv9ErPLJJIZDDpPvEi_-ZdeR8WSxaoQsyplZax_d_QwUpXClUC3J19Dqiz7vzptdwqEUOwhcV6i8hUE4EJ48icVvs226zj6HaYBLOayX6naO12GN2K0VikdEJ6gVq7qFXrO5TozyVPwssFx0wsBT1__KhSyL8PdhQH1rc7IFxJEWEs-vblDYPj3aOrao8LRoq1VSc-YIiE_OBac2LeIKmhBYW8PnYVUd5K4axYnbur2FS2Wqv2bt1jJMwH-1HjNkQ8Pu513wljfQCOC0TXDk-6T5TEtxUU9n2c7qnJSmefcV_m5od2Tqvx4yiz3qS9cBnjSmMoMduBGuL1QzHYAuJgQ0e9E7pLcsIFUWoDEWdwlRXxPYrTTkWBUe6A2BiS2qK932vckg-5qkXwc3rVhs4T_FxkakhGpng4J2gKoq-SKAjXprkahwrg"""),
        V(sam, lou, """{"b":{"text":"On the 305"},"f":"3c157621a97cf055f5804a9826c6d1e1","k":"message","n":"vector-3","t":1800000000,"v":1}""", sig = """C-Wt4CDWC_JyBVNuBtPk1-FVV0yP9g5FRScvJjRJ0SgkyfRf6VjOUIxh-SOHDwcn9Gwb0HB3yYABiE1vVttEDg""", eph = """a0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebf""", ephPub = """605a725d2a4adfeeb1a29e17edd621c1b7593ee8cdbc44ac6c4ab6e2f805d23c""", nonce = """c0c1c2c3c4c5c6c7c8c9cacb""", key = """3efcf6f8bda00486b5377490e2b37b82d3cc3ed26739c9f8d05edf327b356d93""", box = """AWBacl0qSt_usaKeF-3WIcG3WT7ozbxErGxKtuL4BdI8wMHCw8TFxsfIycrLRqFOo-EkGjQPOnM4XKXDadlG8WQ5tpTwi_0U5Uns-Z1xBiFtYMaIN79Cr8oXgKvrJKpNshS2dROPnVqMF4ZKWKh9X26BUeS2PAG57uU0JIwrOkT31H0vHyJLExZLEdgc8G8V6vIfcUMGLzBBzlP3F08iDF01gGFFCVZ1wpQLZ_rebRG0027r_zRGQrqduN2jMcme7z31aWLls0bxjcI1WO7CRPhIz51mRqY6BHNTiftUnyUDY3ZU2HUHj3EBO1Y2cDIbJg"""),
        V(sam, lou, """{"b":{"admin":"3c157621a97cf055f5804a9826c6d1e1","members":[{"card":{"a":"4BkenPteSyzMhZGAEzxCVDtPbsYAfktcUGCFY_f6wTQ","s":"Pimf5pXMDZx03fVhlCwafY9i6il4P1yqNBRkQCW0IMI"},"name":"Sam"},{"card":{"a":"mJcwSQIqMduIElgAV4WiNQyNWrNO9pXpcmuy_ro-H14","s":"jovYuOL-kNKocNr5m2ZGyLdEWYo8qECxLRmVm84HQ_8"},"name":"Lou"},{"card":{"a":"hJSg_nl1Q_a3QwcIgBVBmLQc5cpx3Ms_dPHOjgUNOkw","s":"Qtw5rLliG2yuURUMcKjC0IvUhAYP4Rvx-ZpKIdyflYI"},"name":"Kim"}],"name":"Uni crew","rev":1},"f":"3c157621a97cf055f5804a9826c6d1e1","g":"0123456789abcdef01234567","k":"group","n":"vector-4","t":1800000000,"v":1}""", sig = """pBsY4bQds41vtaz4g7u3p-_hoHtfyVx84qyUzxpHU_IUKWHSP8h9jZ3ryGMMvaGqf80SDXz04W2GHbnaz3r8Cw""", eph = """d0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeef""", ephPub = """6b3ee67463583cbe3dc08fe9d0765c2666ff5210dd527c9d8705e44927c80d55""", nonce = """f0f1f2f3f4f5f6f7f8f9fafb""", key = """758ec218842a5fd19f9e05fea11e7753846f76f522134946b9709f4d2ebadee6""", box = """AWs-5nRjWDy-PcCP6dB2XCZm_1IQ3VJ8nYcF5EknyA1V8PHy8_T19vf4-fr7kQajN_ueiSFAQU_1PF_phMn7SqcyQOUkHfuuVVyQb3zCY_Q78mmKFMHYUmhGAX1ghsvUdKUoBBG-EvRBuUKUtIx3K37SJa8BKVsrFT6yhtBic79k3gLb2E_y7r1Fh5PgpVI8o5b3JyiWjk0aTBOEEXncwES2AHJmkR44GDRdpVad9xr_8pVFOuHgXdfV8piLGKp5K0GSPaFzNZ25jG1ZNtEeXT25aBag_LEEPJZsOyaOHXYMHddtGnFsokBFh12AaG42Lyr_IvAgluB-LETEKwCMEfiFGBtl-SOi9vrYh-4D78UZMRWjw6GRbK79Y2pgkU_BLN03OZxvO7mjHzzcrnB6FpHRM1BUeP8ftOzLVva4p1dV3sSGWcYy8V9eDeL5G8-BFlVq7lTiKV9ccDPliEOYKeXO2uS1GS3piSzbWsXRMGed9_Kt8Hiv0IeoaiGky-VJV2QtU_Jt0YRu7BbOLr4FuMUNKG7I2C4F3PzKsAkylxyCVUw3dUSR2qGoWcu2sY85bHlHoq_3BYCbGiNNPCDeEbsi6UUApGBeWUmn_xaO6i1ISh8X8-IonqYcc3Fve1Ye6wn5wWaeL_ql6QBsSogf74idv-jjQ_TPXypJN0VSEWvaElcsAv-KQj56SeebJtH1FC-cSvuD43y9QJZueL0gs4xS1J9h82NtAIaiVAppbNDl9GfNde2msMqJNbxaLvEQbOwIDlBi2yLVnlgGPdHlZ4V7myrnMK-3eywOnebPrc61CQfP1LBM8jhQomMYA4unx5xtyx02awDDGnlx8Q-jNCotQTTj1N0EjsU4PApiwaAtEUIhy4thnujUFBzIe0dCreXmLRJlnQm-ESrwfZ1zrGJkiRIPLVPVkFBbPbLikA"""),
        V(kim, lou, """{"b":{"text":"Save me a seat"},"f":"9bc64cbb2dab5f14d76c61166b324b98","g":"0123456789abcdef01234567","k":"message","n":"vector-5","t":1800000060,"v":1}""", sig = """Jhg6KmEvwF4SdBCDObQIeS3uq8-ZIiQlc0-Q2n2dKTVExpkQTr7xvdUmMeSAgu93_M-AWm_SsLvSIxfaU4Q3Cg""", eph = """0001020304050607080910111213141516171819202122232425262728293031""", ephPub = """c1e0c8f5681ecdbdfeed4aaa5499ce9754d0f4719a9e0c1781cd78fed23da714""", nonce = """a1a2a3a4a5a6a7a8a9aaabac""", key = """5079c9de688bad36d193a73ab98f2f54678828ee64965e988768abefe4ad4f97""", box = """AcHgyPVoHs29_u1KqlSZzpdU0PRxmp4MF4HNeP7SPacUoaKjpKWmp6ipqqusROmx4BC81O-NVmsLma46Q0CUd3NKmrHkOWfkSa8yKCHm1OZDiTViVTjXcXkSa7WDl2FS6BBd-h-Hpro_8R6nAHlgfo9-4g_1xrwCZ-Nw_os6KQFFKACdfSxBWOx7oci5R2mtdBslgqqxTNRHbQRb1_ih-J2eCqYDWZolXh9qys-UlU6ErdtHPUMkyLRmhMXGfmC8LcZ6x7mbQiDQYlV7ZcF7FMXyfeIEYqWZsACSGSzaSHOS8F2GDu4UcU1ytROhPpBDj2Dy1p69Xc1MfFVTWGaU0Gs7m9uwFp846SpdQ8mucHtIRXR6"""),
        V(kim, sam, """{"b":{"text":"Save me a seat"},"f":"9bc64cbb2dab5f14d76c61166b324b98","g":"0123456789abcdef01234567","k":"message","n":"vector-5","t":1800000060,"v":1}""", sig = """bAKqe-KrGg2v1BNSYti8EiCsyMWjgU6FWhqZzWZXuUFvkHdyMHEBlEK9ejv5ZQncm0wj_E437snlsUn-SHv9AQ""", eph = """3132333435363738394041424344454647484950515253545556575859606162""", ephPub = """670e9ff7441bdd5ca886e26ad4e18e9bd9b4edf52219efc071cdc13eee9d8e43""", nonce = """b1b2b3b4b5b6b7b8b9babbbc""", key = """c753e93d8362807e72e785f78fa0ad24c43947d0c15d497b73aa1e5330f9fc19""", box = """AWcOn_dEG91cqIbiatThjpvZtO31IhnvwHHNwT7unY5DsbKztLW2t7i5uru8X_0tIgokGLQwviDssVFErIKZLgBN4n9Ft_NgAecydT0R0HNxCU-aObfKdaOHukE72nxbw9Gy8Q5KgMc6ZhUbCUZ0p5V_IIN_5IuXJyp1dml47nVifyi9BPswrJao7VRp4BDGYtq5c79B7SAYdDwJxGhrnEyw1aaln2YiZ2BRAf69RN97XCfh0embpOOcsUIBeg07-syRxm5dwbV_XKwhAd3uKBoYD_TXZxI2cqKzDcepW2_IjIP7QRJOlj8nYp30DkWKrvc5hORftcKsUzX14znV2qdVqOJ9rC3TEOqkYenWhZWCScal"""),
        V(sam, lou, """{"b":{"by":1800006000,"end":1800005400,"note":"Take the 07:41 with me?","rides":[{"arr":1800004200,"dep":1800001260,"from":{"id":"vector-stop-ehv","lat":51.44306,"lon":5.47917,"name":"Eindhoven Centraal"},"line":"IC","mode":"train","name":"Intercity","num":"3512","plat":"4","to":{"lat":51.59556,"lon":4.78,"name":"Breda"},"trip":"vector-trip-3512"}],"start":1800000900,"to":{"lat":51.5866,"lon":4.7745,"name":"BUas"}},"f":"3c157621a97cf055f5804a9826c6d1e1","k":"trip","n":"vector-6","t":1800000000,"v":1}""", sig = """_YY3pPeiv3WsTZ3ZZeygo1iajicOqqoD0_w6TwlMRBgIy81h1jlkHHAb_-XcQ_uUaxb9vmdUW6rcP3EB1zGQCA""", eph = """4142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f60""", ephPub = """64b101b1d0be5a8704bd078f9895001fc03e8e9f9522f188dd128d9846d48466""", nonce = """d1d2d3d4d5d6d7d8d9dadbdc""", key = """8f2c28ea802e79215bdb91f010e5b080b7aed30f50c3f2a036a86a1176891f7f""", box = """AWSxAbHQvlqHBL0Hj5iVAB_APo6flSLxiN0SjZhG1IRm0dLT1NXW19jZ2tvcpaSNBO2NCnxoHbkx--22UkdLqhhsh635p0DInyf9QvRoR1cpULartizgPTxXhw1XJpxxnvKFqjs1ha4LCODhIuaxG6DtiYR3fAhainRDLsW0alzRKpSOi8GTm5XfR9CEFIpY-t1K-4NCeSqQmij51Cy1REq4SAd1-b94OekuxLgorNquCM8DTWdhPjTef3HmdAyj1wmaJyXGDbHT162MzM1t5gg1VgJ9Jt4DPu1mBkNE5neZ7PywC3aqmWhb999D7vhHXabuWPzFQGTbheixFbyfBltcHxU-idHXWVaq1uRFZA9VFJatwOQRHQoCTK8tK9akQAWP9B675E9FswCbHxy-9Xp6otJstsA2VuxwimjDcpQ6qb6NbH7hkbIXWCGpCKUNFjo37-ifvvO6zzmILfSlU5oRfGkVLUsA_Yi8rH-HxX0y7FqJHg6wn-LmWEmjZkoqeRn-nWhu4FUqASz1bgA4cuy1F-4JSJoZqBCQXYvzR1Qmpxn22eHBO9JF2UiXmP2HlKglZ59NB10CDDRJfmttE3K4jdDG4WVVyE9h6P17MfAZWSPUfl3i-56IbFsqrsTvslYZtY0h4NaB_aELuMxppojQVdy2TxvSfcjIm2WmNx9VUxYA24JnodKoazK4GP9VAQqCEVGombnhzwgnFzQPMq22fVeUyeqM6U2eW6k-aQH1A8YYGRb4ADeOx8xr9WMkqrpPaaPeBtDSZNUKRaxDjmLGN4dzIgElHXLC9IvilHR0-dOu2ONt-mCKaLcSM13AqwGKxHYW"""),
        V(lou, sam, """{"b":{"answer":"in","re":"vector-6","text":"I’m in"},"f":"65392c81aa86e697083b0960bf107afb","k":"message","n":"vector-7","t":1800000120,"v":1}""", sig = null, eph = null, ephPub = null, nonce = null, key = null, box = null),
        V(sam, lou, """{"b":{"classes":[{"end":1800010800,"room":"C1.02","start":1800004500,"title":"Design"},{"end":1800024300,"start":1800016200,"title":"Maths"}],"from":1799967600,"src":"calendar","to":1801177200},"f":"3c157621a97cf055f5804a9826c6d1e1","k":"timetable","n":"vector-8","t":1800000000,"v":1}""", sig = """PhtJtWWwYne2jAvNgh5dBivMMs3MYal36jGMHf91URegi3vJOFDnTX0frmmjT9YZbsI9UV-73lkwk2sUBGeMDA""", eph = """e0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeff""", ephPub = """736845d54e87de09d6bb114aa7042c50a4a015bd9901d1a0026f5956533a1519""", nonce = """0a0b0c0d0e0f101112131415""", key = """24ac3b6697d3e534b1d114ee317b401608258e500d3224cac9783a9641cc0cf1""", box = """AXNoRdVOh94J1rsRSqcELFCkoBW9mQHRoAJvWVZTOhUZCgsMDQ4PEBESExQVUxMTxDR2FAxkJX3qhoNrBCJncUIfOfkfJjntZ0pd8fh1vrOGo-Sys35eTTnNHXM-Az3pzc_CH_XS_TIA9hRe6PMo321YrlGo3tfPC10VxchYYlzyAER-DubzI_Ix_3ALwatYL9PW0TmCATUVWG_UBXAbN7fkj8RioTXAa2EmWbWnpt38MYvc6sVFvYKTru2KsvRPZkqpS4wHmndn0-T4FE0g3Ey_vm4YZcw4i4riTdqYUmRFtHjCEpo7AbXb_MXgb4TgPdfZ-m-yX1YLptvqZXDSLx716k3zFL_Po4whHeR8Ds6q7uTZJpvF9uRnSIQgqG_NXv7C95b89-W3kDlBIc8aPhmKfH03cGrgp6wsvK8P-rPOvKdaYs2e30A4g6bFjnGnHRESID5IJog5ROBAQoG1EkrDeGE1SPudxqn5lSW6dNfGtCC1dXB8kGcHOoHCaBBlrH4fdgSCl77ft98vH1Hd_rfeRg6TYh0IhaM"""),
        V(sam, lou, """{"b":{"early":10,"school":{"lat":51.5866,"lon":4.7745,"name":"BUas"},"station":{"code":"EHV","lat":51.44306,"lon":5.47917,"name":"Eindhoven Centraal"},"stops":[{"id":"vector-stop-1","lat":51.4401,"lon":5.4789,"name":"Eindhoven, Station"}]},"f":"3c157621a97cf055f5804a9826c6d1e1","k":"area","n":"vector-9","t":1800000000,"v":1}""", sig = """Ss9LsAU1yEaX78X0NNGZFVbmMGCXyExL5bWwVVSymzYmKLKb_MhS1ygSw5fsTHnDaCSo7OIwxLpf6-TAM0PDDA""", eph = """1112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f30""", ephPub = """4d27bcee3135c4944b28d27dd809b07be10c35160d20131caa7e85575498d07c""", nonce = """161718191a1b1c1d1e1f2021""", key = """4423045437c7bc86a7785ab582f3d1484d4ebebb030362781ef112ebaf53947b""", box = """AU0nvO4xNcSUSyjSfdgJsHvhDDUWDSATHKp-hVdUmNB8FhcYGRobHB0eHyAhU3XtQHq-Kuv74wBPlsCOmaWksIfkUDbPCW0apmIKieezb6cFqAZ63AHeQe4XXFDv76oFbqYeUij9rl0PMQwxkFmNZgK2Mg1oqBp3sDufRowOyjVrcRDaP4obdhOlN9ot0tQ4Iuifd4oCvkFWMc7MhWNZ8eVA0IXLBIlTsRiQoysMZ1CxgTULPogfMBFoCh9g0vu1ZWsd58izUufy1Zl2uL3_X5bnb0_hJuCQrmKMlkzJeIWTVxGQbRiq5ap13GALwBblYhO2Y10ZWjIynlfs1LIFG3E5uKAViR74WGG4inY-wV5asAhgo2VkMJsPV4aLkjZUJxpAF26TVVBXl2K_S95hD66KYH2QqrQp7zy1AnEn6iyP-tz-lg3Rxpf5_8LliKgaRCufXpu0qgq-gJsiiqeHwibhVEBwOQUIZV0couDS9kiCU-tkao2VcGmfgsfxgliM-1R9Dxat4OU8GvYy4t3SwoL6ukAMlKxbSQOArQD2KY5y400LatGpejnkyR_SY9eLh44yqGSg_OrieMUPzKSPwZOd1A"""),
        V(sam, lou, """{"b":{"classes":[],"from":1800000000,"off":true,"to":1800000000},"f":"3c157621a97cf055f5804a9826c6d1e1","k":"timetable","n":"vector-10","t":1800000060,"v":1}""", sig = null, eph = null, ephPub = null, nonce = null, key = null, box = null),
        V(sam, lou, """{"b":{"at":1799999990,"dist":300,"eta":1800000120,"id":"vector-wait-1","ride":{"arr":1800003720,"dep":1800000660,"from":{"lat":51.44306,"lon":5.47917,"name":"Eindhoven Centraal"},"line":"IC","mode":"train","num":"3512","to":{"lat":51.59556,"lon":4.78,"name":"Breda"},"trip":"vector-trip-3512"},"state":"coming","stop":{"lat":51.44306,"lon":5.47917,"name":"Eindhoven Centraal"}},"f":"3c157621a97cf055f5804a9826c6d1e1","k":"wait","n":"vector-11","t":1800000000,"v":1}""", sig = """dvEcw94cpL8gWf9Pk5zYUIs1-BuEqsDFUGLCyxkupqCyiFUZQNQ2u9kTLUICfKy0W_EOElr6dHRbdLfVWwJDBA""", eph = """5152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f70""", ephPub = """0233f006ef4bed144ea0a5bb46c7067c7c2acec5f8cc811f3df59fdcd5ac7614""", nonce = """7172737475767778797a7b7c""", key = """dcb844e611ba42e669c113ac7cc329bd2e7fd7f9de9a2743a35ee2c097803da9""", box = """AQIz8AbvS-0UTqClu0bHBnx8Ks7F-MyBHz31n9zVrHYUcXJzdHV2d3h5ent8F4o711H-IQXcNO0jPzR1Ejq4_JNB8y8vGAu7V-8zdOX1UD3N50pM00P_1ADbwrE3h2wmhHcHqQEz3aRrX0n3sIOzc-UWOECBBaxHwmpFfUoOHcakg99KDVQeMqmhhAYlfNcUv5s09i7WlXYo67QXcMQAxr5LJm72nq6ZhSNVBXjGtjFHTuuUCl3ilkUa-8nepuYvnJSCbcLXRclEJUDxFeVEBO0-6NXuHP7FBDo7mTMP-TARfC1o7ZDV-dK67xSB-CeKwDJZelbIe7_mUIBbkv8lrXudYV_1qhsBCp-CBR_-XRSu-07ceS9do_vOnz6YQ0DSo-ec87gJn-J9jQlxYOWYhVezq9ZwxIOH-pLym5h0uZeYGhN6PAxlBQRZwJIbRILXFpqypJm36Ly9CjU7nxsZrGRMtrqmDTHxkSQwmbl9UTpgf6yZxz0BzBEAvOcz2ygKb8SITHbSbyaVL4TwQel2xRmpgMVfpe4KwaYlxTXLz6TObtYy6Kmx1urlARXMP2lRhDfH3TGnzA8Qq00AH43ryoWsZGtF4j7E6FSV5Jq1qAtOo7qIFPIx0XttCjdbaCUyfu-U_w0tz8Sh6hapPzAcJCYeI0UOgzsw63llntPRDyN9qb1pNHrKPIbHaSLdFV7tGH11uhMG9r7u92952kkBSFh9EeAuhn1nswYrEnL9vsH-K4aLg8PR1oTtR10ifQ5FF5YVTZWlzrrn66h83XM"""),
        V(sam, lou, """{"b":{"on":true,"school":"BUas","since":1799998500,"until":1800034500},"f":"3c157621a97cf055f5804a9826c6d1e1","k":"campus","n":"vector-12","t":1800000000,"v":1}""", sig = """KZJaSU7N-X7-nf4ppDL55RLL8r1QNVvZk4tS_e-5MVXjklHFbv0DrckGuITkgbOQBMkqpwd-ZiiN2NKaHm0IAg""", eph = """8182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0""", ephPub = """883186b800b41d5cf0429695da9b3cc4f328ebcd184a6e482fa578c103f06c77""", nonce = """c1c2c3c4c5c6c7c8c9cacbcc""", key = """f1cbd7bf15bd198183f9df1d2c458781e5410eb1b5dc19f8464f81f8bc9c7341""", box = """AYgxhrgAtB1c8EKWldqbPMTzKOvNGEpuSC-leMED8Gx3wcLDxMXGx8jJysvM7sUXIpFk66f2MxcXYYb_tMTT0JGE-coRJl94y_gjkkUpyQ_ek_2yhJS6fKfMo-pj9FNhe4peWbLP9HKoM4MKBl28GjWBJwVOwQ4G6cVMY_hDekvjQ95EHvOI39blGlgywHJi9oPKRZ9Ekxmlt8QzpLsk5t7xneAEPe-cObvOIgpDj3rPTKtBac__D4tMib7wYbiF-RVet2Ye-iIf8ku1lYuiCOEuXyBMNYvzEWPO3nv_ROSbsh9G7-jmTcDLepeX-ajit0lGM0KX8xALe_wdEIUXHrqadwbnll2Rvzk-2tVpM2Swb0y6udi-r5frt2Ai"""),
        V(sam, lou, """{"b":{"day":"2027-01-15","leave":1799994000,"on":true,"ride":{"arr":1799998320,"dep":1799995260,"from":{"lat":51.44306,"lon":5.47917,"name":"Eindhoven Centraal"},"line":"IC","mode":"train","num":"3512","to":{"lat":51.59556,"lon":4.78,"name":"Breda"},"trip":"vector-trip-3512"}},"f":"3c157621a97cf055f5804a9826c6d1e1","k":"buddy","n":"vector-13","t":1799992800,"v":1}""", sig = """Zazseam6h_FFLC8gnZaYfx4ukSG2Dl2YbRSObRDZa9odsX5tHpyA-HpdHZJeZLEg3OQ91RYkIEUGzw8N6jR-Dg""", eph = null, ephPub = null, nonce = null, key = null, box = null),
        V(sam, lou, """{"b":{"late":6,"next":{"arr":1800004860,"dep":1800001800,"from":{"lat":51.44306,"lon":5.47917,"name":"Eindhoven Centraal"},"line":"IC","mode":"train","num":"3516","to":{"lat":51.59556,"lon":4.78,"name":"Breda"},"trip":"vector-trip-3516"},"ride":{"arr":1800003420,"dep":1800000360,"from":{"lat":51.44306,"lon":5.47917,"name":"Eindhoven Centraal"},"line":"IC","mode":"train","num":"3512","sdep":1800000000,"to":{"lat":51.59556,"lon":4.78,"name":"Breda"},"trip":"vector-trip-3512"},"who":["3c157621a97cf055f5804a9826c6d1e1","65392c81aa86e697083b0960bf107afb"]},"f":"3c157621a97cf055f5804a9826c6d1e1","k":"delay","n":"vector-14","t":1800000000,"v":1}""", sig = """hvyCU_Sk36bcLvd52FSIHuHI37Ni_qQhs7_Rpnmy5B_2hlbgSa2d47QAXRfYbBzbLV8gMvcS_c4zlVL_wJdZAA""", eph = null, ephPub = null, nonce = null, key = null, box = null),
        V(lou, sam, """{"b":{"answer":"wait","re":"vector-wait-1","text":"I’ll wait"},"f":"65392c81aa86e697083b0960bf107afb","k":"message","n":"vector-15","t":1800000030,"v":1}""", sig = """quv2P-b4oVOMfuXKCxJIVQIMwkH9zSq25Djgu81cSa7uWyaFt7gjlmcnX5kqidzMy_K-R9OC9PMbuWXzC8xDDA""", eph = null, ephPub = null, nonce = null, key = null, box = null),
        V(sam, lou, """{"b":{"best":[{"at":1799996400,"home":false,"mins":48.5,"route":"home→school"},{"at":1799910000,"home":true,"mins":52,"route":"school→home"}],"mbest":[{"at":1799996400,"home":false,"mins":48.5,"route":"home→school"}],"month":"2027-01","on":true,"rides":14},"f":"3c157621a97cf055f5804a9826c6d1e1","k":"scores","n":"vector-16","t":1800000000,"v":1}""", sig = """6rLh_QChtON4H7TK4hzq8a0UxhBkm55Zq67PCwiZFCholCtVlWmo5R_13XRlGu7Vb3wcZU9wVpqMKxKcSoqcDQ""", eph = """9192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0""", ephPub = """9cced751b301bbd16c4fb8deddd82f18925d71ed90c844fa0158f845b0fa7f4b""", nonce = """d1d2d3d4d5d6d7d8d9dadbdd""", key = """a656690c6bb10400c938ea7f1888af6f348a47c5d7f09d7317eaee094ff8a41e""", box = """AZzO11GzAbvRbE-43t3YLxiSXXHtkMhE-gFY-EWw-n9L0dLT1NXW19jZ2tvd2yVEWneoEWqLeQL9E6U4tx_P1PQUZHFE0SJnGsrRekEFLdfQJJ5WTl07a8y-r1W9TrD3wY0xRFCfEXBmplz4mbB53BKkqZiLX1r8JAtjw4gc3cCshJuxPi5wI6VyWk0syVe7ZR6lvKJVRH9hMzJtULbGBPzrLoZSB9OXwcj5PnVuQUZcc6tJiAi8C6pFIfu05GXTXY97-zshmL0FOGC7GmeF2WBWojbxnt4SHwxt0VX4zc625bdH-6DVzm-mNejIBbheioXp_XLn39U4-tf3dhUMB8aarwPDxeQKawwjQjgXC2ZMVveb5jvkKqLEvjEv7zSVITyNma_T9cjEgvmZQi1Drlfv5TGcVOzF8Zlli2sWQFAtU6tdXEiqw_PW-jqIYHH7psu0FGzeLPbO_HWKJ__71nlMtqW9VptFYoHTdOjNjDHStEm5x8fMsXwAOW2thjzBvyctDHCJk0LZCgHQBCGgAt45xCgHTDViqG97IYH-qzRN6VNIavLbEhvui4514nG_Usol_5kP2S0j2gpM_B59rPMkNF4cTFLygK7GN9AXWtLKkTO5zMqD0dF4V4vm"""),
    )

    @Test fun seedsGiveKeys() {
        assertEquals("3e299fe695cc0d9c74ddf561942c1a7d8f62ea29783f5caa3414644025b420c2", Hex.encode(sam.signKey))
        assertEquals("e0191e9cfb5e4b2ccc859180133c42543b4f6ec6007e4b5c50608563f7fac134", Hex.encode(sam.agreeKey))
        assertEquals("66cd8d6137776253f8c7b0e625a6fcfb23d7ce0498f85e22f5a2fd51a229e819", Hex.encode(sam.vaultKey))
        assertEquals("3c157621a97cf055f5804a9826c6d1e1", sam.account)
        assertEquals("Pimf5pXMDZx03fVhlCwafY9i6il4P1yqNBRkQCW0IMLgGR6c-15LLMyFkYATPEJUO09uxgB-S1xQYIVj9_rBNA", sam.card.packed)
        assertEquals("8e8bd8b8e2fe90d2a870daf99b6646c8b744598a3ca840b12d19959bce0743ff", Hex.encode(lou.signKey))
        assertEquals("98973049022a31db881258005785a2350c8d5ab34ef695e9726bb2feba3e1f5e", Hex.encode(lou.agreeKey))
        assertEquals("65392c81aa86e697083b0960bf107afb", lou.account)
        assertEquals("42dc39acb9621b6cae51150c70a8c2d08bd484060fe11bf1f99a4a21dc9f9582", Hex.encode(kim.signKey))
        assertEquals("8494a0fe797543f6b743070880154198b41ce5ca71dccb3f74f1ce8e050d3a4c", Hex.encode(kim.agreeKey))
        assertEquals("9bc64cbb2dab5f14d76c61166b324b98", kim.account)
    }

    @Test fun backupCode() {
        val words = "abandon amount liar amount expire adjust cage candy arch gather drum buyer".split(" ")
        assertEquals(words, sam.words)
        assertArrayEquals(sam.seed, FriendWords.decode(words))
        // any case, the first four letters, a wrong checksum
        assertArrayEquals(sam.seed, FriendWords.decode(FriendWords.words("1. ABAN amou, liar - amount expi adju cage cand arch gath drum buye")))
        assertNull(FriendWords.decode(words.dropLast(1) + "zoo"))
        assertNull(FriendWords.decode(words.dropLast(1)))
        assertEquals(2048, FriendWords.list.size)
    }

    @Test fun everyBoxByteForByte() {
        var boxes = 0
        for (v in vectors) {
            val p = v.payload.toByteArray(Charsets.UTF_8)
            val sig = B64u.decode(v.sig ?: continue)!!
            assertTrue("signature of ${v.payload.take(60)}", FriendCrypto.verify(v.from.signKey, FriendBox.signed(p, v.to.account), sig))
            // deterministic Ed25519: the same signature as Node's
            assertEquals(v.sig, B64u.encode(v.from.sign(FriendBox.signed(p, v.to.account))))
            if (v.box == null) continue
            boxes++
            val eph = hex(v.eph!!)
            assertEquals(v.ephPub, Hex.encode(FriendCrypto.xPublic(eph)))
            val shared = FriendCrypto.agree(eph, v.to.agreeKey)!!
            assertEquals(v.key, Hex.encode(FriendBox.boxKey(shared, FriendCrypto.xPublic(eph), v.to.agreeKey)))
            assertEquals(v.box, B64u.encode(FriendBox.lock(sig + p, v.to.card, eph, hex(v.nonce!!))))
            assertEquals(v.box, B64u.encode(FriendBox.seal(p, v.from, v.to.card, eph, hex(v.nonce))))
            // and it opens on the other side, from the cards a phone would know
            val o = FriendBox.open(B64u.decode(v.box)!!, v.to, v.from.account) { cards[it] }
            assertEquals(v.from.card, o.sender)
        }
        assertEquals(12, boxes)
    }

    @Test fun payloadsRebuildExactly() {
        var n = 0
        for (v in vectors) {
            val p = v.payload.toByteArray(Charsets.UTF_8)
            val (h, m) = FriendBox.parse(p)
            if (m is FriendMessage.Unknown) { assertTrue(h.k in setOf("wait", "campus", "buddy", "delay", "scores")); continue }
            n++
            assertEquals(v.payload, String(FriendBox.payload(m, h.f, h.t, h.n, h.g), Charsets.UTF_8))
        }
        assertEquals(12, n)
    }

    @Test fun kindsAsRead() {
        val byN = vectors.associateBy { FriendBox.parse(it.payload.toByteArray()).first.n }
        fun msg(n: String) = FriendBox.parse(byN.getValue(n).payload.toByteArray()).second
        assertEquals(FriendMessage.Request(FriendIntro(sam.card, "Sam")), msg("vector-1"))
        val travel = (msg("vector-2") as FriendMessage.Travel).state
        assertEquals("IC", travel.line); assertEquals(3, travel.coach!!.n); assertEquals(1800003780.0, travel.eta!!, 0.0)
        assertEquals("On the 305", (msg("vector-3") as FriendMessage.Message).text.text)
        val roster = (msg("vector-4") as FriendMessage.Group).roster
        assertEquals(listOf("Sam", "Lou", "Kim"), roster.members.map { it.name }); assertEquals(kim.card, roster.members[2].card)
        val card = (msg("vector-6") as FriendMessage.Trip).card
        assertEquals("vector-trip-3512", card.rides[0].trip); assertEquals(1800006000.0, card.by!!, 0.0)
        val answer = (msg("vector-7") as FriendMessage.Message).text
        assertEquals(TripAnswer.YES, TripAnswer.of(answer.answer)); assertEquals("vector-6", answer.re); assertEquals("I’m in", answer.text)
        val tt = (msg("vector-8") as FriendMessage.Timetable).share
        assertEquals(2, tt.classes.size); assertEquals("C1.02", tt.classes[0].room)
        val area = (msg("vector-9") as FriendMessage.Area).area
        assertEquals("EHV", area.station!!.code); assertEquals("vector-stop-1", area.start!!.id)
        assertTrue((msg("vector-10") as FriendMessage.Timetable).share.isOff)
        // an iOS 0.29 answer to a wait reads as plain text here
        assertNull(TripAnswer.of((msg("vector-15") as FriendMessage.Message).text.answer))
    }

    @Test fun kimsGroupLineOpensFromTheList() {
        // Lou isn't Kim's friend: only the group's list gives Kim's card
        val toLou = vectors.first { it.to === lou && it.from === kim }
        val o = FriendBox.open(B64u.decode(toLou.box!!)!!, lou, kim.account) { if (it == kim.account) kim.card else null }
        assertEquals("0123456789abcdef01234567", o.header.g)
        try {
            FriendBox.open(B64u.decode(toLou.box)!!, lou, kim.account) { null }
            throw AssertionError("opened without a card")
        } catch (e: nl.haltewekker.friends.FriendBoxException) {
            assertEquals(nl.haltewekker.friends.FriendBoxError.UNKNOWN_SENDER, e.error)
        }
    }

    @Test fun signedRequests() {
        val body = """{"after":0,"limit":100}""".toByteArray()
        val text = RelaySign.canonical("POST", "/f/v1/inbox", sam.account, "00112233445566778899aabbccddeeff", 1800000000, "vector-nonce-0001", body)
        assertEquals("HW1\nPOST\n/f/v1/inbox\n3c157621a97cf055f5804a9826c6d1e1\n00112233445566778899aabbccddeeff\n1800000000\nvector-nonce-0001\n6d91ff60bfde16a24f2bf5ef2516cdf9e47c5d2d54f6e04b5e538046377e375f", text)
        val h = RelaySign.headers(sam, "00112233445566778899aabbccddeeff", "/f/v1/inbox", body, 1800000000, "vector-nonce-0001")
        assertEquals("Al3g11GCpgqXzYqJAH61A3JX_sSHiXIGqlOz5l_8bjR_VQe4R-VUQqXc5Q08xmJ_kGsRYmklpNUdKHXMRJbBBg", h["X-HW-Signature"])
        // the inbox body as the app writes it
        val inbox = FriendRelay.bodyBytes(kotlinx.serialization.json.buildJsonObject {
            put("after", kotlinx.serialization.json.JsonPrimitive(0)); put("limit", kotlinx.serialization.json.JsonPrimitive(100))
        })
        assertArrayEquals(body, inbox)
        // 0.26: /f/v1/state/put with the travel box
        val travelBox = vectors.first { FriendBox.parse(it.payload.toByteArray()).first.n == "vector-2" }.box!!
        val put = FriendRelay.bodyBytes(FriendRelay.statePutBody(listOf(lou.account to B64u.decode(travelBox)!!), 360))
        assertEquals("0c15ebabfaa77e823f6831b5718b0ed587350e01cd3ca08e842971307246ec57", Hex.encode(FriendCrypto.sha256(put)))
        val h2 = RelaySign.headers(sam, "00112233445566778899aabbccddeeff", "/f/v1/state/put", put, 1800000000, "vector-nonce-0002")
        assertEquals("TYjw9PyrJ_a6Y0ahTV_e6jnPN_YsdfOobgbhBIJXyLtokJQvQOCicQpl-ZnmZPbFJlCmYLw8vXV8YcZl6ikHAQ", h2["X-HW-Signature"])
    }

    @Test fun vaultByteForByte() {
        val plain = """{"book":{"friends":[],"incoming":[],"myName":"Sam","outgoing":[],"v":1},"v":1}"""
        val sealed = FriendVault.seal(plain.toByteArray(), sam, hex("505152535455565758595a5b"))
        assertEquals("AVBRUlNUVVZXWFlaW53946SaBXtO59uYSRBJF1zTgHIUdVubOEKiCPQ5MEnqVJhxImhJYxfVnyjS4w0TLI9xA_AKoX6RlIIvJ7G5PfhNK7konHLAQ40zqQx-Qhj8QDR6WwPW0HRNmTwNp40", B64u.encode(sealed))
        val back = FriendVault.open(sealed, sam)!!
        val c = FriendJson.decode(FriendVaultContents.serializer(), back)!!
        assertEquals("Sam", c.book.myName)
        assertNull(c.picture)
        // the app's own writing of it is the same bytes
        assertEquals(plain, FriendJson.encodeString(FriendVaultContents.serializer(), c))
        assertNull(FriendVault.open(sealed, lou))
    }

    @Test fun jsonIsPlain() {
        assertEquals("""{"jpeg":"_9j_"}""", FriendJson.encodeString(nl.haltewekker.friends.FriendPicture.serializer(),
            nl.haltewekker.friends.FriendPicture.of(byteArrayOf(0xff.toByte(), 0xd8.toByte(), 0xff.toByte()))))
        val f = nl.haltewekker.friends.Friend(sam.card, "Sam", 1800000000.0)
        assertTrue(FriendJson.encodeString(nl.haltewekker.friends.Friend.serializer(), f).contains(""""since":1800000000"""))
        assertEquals("51.44306", FriendJson.number("51.44306")); assertEquals("1800000000", FriendJson.number("1.8E9"))
        assertNotNull(FriendCard.packed(sam.card.packed))
        assertEquals(sam.card, FriendCard.packed(sam.card.packed))
    }
}
