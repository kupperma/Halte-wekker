package nl.haltewekker.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import nl.haltewekker.BuildConfig
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.concurrent.TimeUnit

/** An answer: its status, body and ETag (null body: no answer at all). */
class NetAnswer(val status: Int, val body: ByteArray?, val etag: String?, val retryAfter: String? = null) {
    val ok: Boolean get() = status in 200..299 && body != null
    val text: String get() = body?.toString(Charsets.UTF_8) ?: ""
}

/**
 * One HTTP client for the app (iOS `Net`): a short time limit for what someone waits for on screen, a longer one for
 * the rest; no retries on its own (the callers decide), and the server's cache headers kept (ETag).
 */
object Net {
    val userAgent = "Haltewekker-Android/${BuildConfig.VERSION_NAME} (https://github.com/kupperma/Halte-wekker)"

    val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(25, TimeUnit.SECONDS)
        .callTimeout(30, TimeUnit.SECONDS)
        .retryOnConnectionFailure(true)
        .build()

    suspend fun get(url: String, params: List<Pair<String, String>> = emptyList(), etag: String? = null): NetAnswer =
        withContext(Dispatchers.IO) {
            try {
                val u = url.toHttpUrl().newBuilder().apply { params.forEach { (k, v) -> addQueryParameter(k, v) } }.build()
                val req = Request.Builder().url(u).header("User-Agent", userAgent)
                    .apply { if (etag != null) header("If-None-Match", etag) }.build()
                client.newCall(req).execute().use { r -> NetAnswer(r.code, r.body?.bytes(), r.header("ETag"), r.header("Retry-After")) }
            } catch (e: Exception) {
                NetAnswer(-1, null, null)
            }
        }
}
