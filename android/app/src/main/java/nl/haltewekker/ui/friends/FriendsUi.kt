package nl.haltewekker.ui.friends

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.net.Uri
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import android.media.ExifInterface
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import nl.haltewekker.friends.FriendNames
import nl.haltewekker.friends.FriendPicture
import nl.haltewekker.ui.theme.DS
import java.io.ByteArrayOutputStream

/** A round picture, or the initials on the accent's soft colour. */
@Composable
fun Avatar(name: String, jpeg: ByteArray?, size: Dp = 40.dp) {
    val bmp = remember(jpeg) { jpeg?.let { try { BitmapFactory.decodeByteArray(it, 0, it.size) } catch (_: Exception) { null } } }
    if (bmp != null) {
        Image(bmp.asImageBitmap(), name, Modifier.size(size).clip(CircleShape), contentScale = ContentScale.Crop)
    } else {
        Box(Modifier.size(size).clip(CircleShape).background(DS.t.accentSoft), contentAlignment = Alignment.Center) {
            Text(FriendNames.initials(name), color = DS.t.accentSoftText, fontWeight = FontWeight.Bold, fontSize = (size.value * 0.38f).sp)
        }
    }
}

/** One row: picture, name, a line under it, and what goes on the right. */
@Composable
fun PersonRow(name: String, jpeg: ByteArray?, detail: String?, onClick: (() -> Unit)? = null, id: String? = null, end: @Composable RowScope.() -> Unit = {}) {
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).let { if (onClick != null) it.clickable(onClick = onClick) else it }.padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Avatar(name, jpeg)
        Column(Modifier.weight(1f)) {
            // (A5) the test friend's "TEST" tag wherever a friend row shows
            val bot = nl.haltewekker.friends.TestFriendBot.account.collectAsState().value
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(name, color = DS.t.text, fontWeight = FontWeight.SemiBold, maxLines = 1, modifier = Modifier.weight(1f, fill = false))
                if (id != null && bot == id) TestFriendTag()
            }
            if (!detail.isNullOrEmpty()) Text(detail, color = DS.t.secondary, style = MaterialTheme.typography.bodySmall, maxLines = 2)
        }
        end()
    }
}

@Composable
fun SwitchRow(title: String, sub: String?, on: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, color = DS.t.text, fontWeight = FontWeight.SemiBold)
            if (sub != null) Text(sub, color = DS.t.secondary, style = MaterialTheme.typography.bodySmall)
        }
        Switch(on, onChange)
    }
}

/** A badge: the count on the accent. */
@Composable
fun Badge(n: Int) {
    if (n <= 0) return
    Box(Modifier.clip(CircleShape).background(DS.t.accent).padding(horizontal = 7.dp, vertical = 1.dp)) {
        Text(if (n > 99) "99+" else "$n", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 12.sp)
    }
}

/** The QR code: error correction M, byte mode, black on white whatever the theme (scanners want the contrast). */
@Composable
fun QrCode(text: String, modifier: Modifier = Modifier) {
    val bmp = remember(text) { Qr.bitmap(text) }
    Box(modifier.clip(RoundedCornerShape(DS.fieldRadius)).background(Color.White).padding(16.dp)) {
        if (bmp != null) Image(bmp.asImageBitmap(), "Your friend code, as a QR code", Modifier.fillMaxWidth(), filterQuality = FilterQuality.None,
            contentScale = ContentScale.FillWidth)
    }
}

object Qr {
    fun bitmap(text: String): Bitmap? = try {
        val m = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, 0, 0,
            mapOf(EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M, EncodeHintType.CHARACTER_SET to "UTF-8", EncodeHintType.MARGIN to 1))
        val w = m.width; val h = m.height
        val px = IntArray(w * h) { if (m.get(it % w, it / w)) 0xFF000000.toInt() else 0xFFFFFFFF.toInt() }
        Bitmap.createBitmap(px, w, h, Bitmap.Config.ARGB_8888)
    } catch (_: Exception) { null }
}

/** A picked photo as a profile picture: a centred square, 256 px, a plain JPEG of at most 40 KB. */
object Pictures {
    fun square(c: Context, uri: Uri): ByteArray? = try {
        val bytes = c.contentResolver.openInputStream(uri)?.use { it.readBytes() } ?: return null
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        var sample = 1
        while (minOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= 256) sample *= 2
        var b = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample }) ?: return null
        val rot = try {
            when (ExifInterface(bytes.inputStream()).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
                ExifInterface.ORIENTATION_ROTATE_90 -> 90f; ExifInterface.ORIENTATION_ROTATE_180 -> 180f; ExifInterface.ORIENTATION_ROTATE_270 -> 270f; else -> 0f
            }
        } catch (_: Exception) { 0f }
        val side = minOf(b.width, b.height)
        val m = Matrix().apply { postRotate(rot); val s = 256f / side; postScale(s, s) }
        b = Bitmap.createBitmap(b, (b.width - side) / 2, (b.height - side) / 2, side, side, m, true)
        jpeg(b)
    } catch (_: Exception) { null }

    fun jpeg(b: Bitmap): ByteArray? {
        for (q in listOf(85, 75, 65, 55, 45, 35)) {
            val out = ByteArrayOutputStream()
            b.compress(Bitmap.CompressFormat.JPEG, q, out)
            if (out.size() <= FriendPicture.MAX_BYTES) return out.toByteArray()
        }
        return null
    }
}
