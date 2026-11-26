package nl.haltewekker.ui.friends

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer
import nl.haltewekker.friends.FriendLink
import nl.haltewekker.friends.OpenedCode
import nl.haltewekker.ui.QuietButton
import java.util.concurrent.Executors

/** Friends › Scan a code: the camera (CameraX), each frame read by ZXing for a QR code. No Play services. */
@Composable
fun ScanScreen(onFound: (OpenedCode) -> Unit, onCancel: () -> Unit) {
    val context = LocalContext.current
    var granted by remember { mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) }
    var asked by remember { mutableStateOf(false) }
    var wrong by remember { mutableStateOf(false) }
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted = it; asked = true }
    LaunchedEffect(Unit) { if (!granted) ask.launch(Manifest.permission.CAMERA) }
    Box(Modifier.fillMaxSize().background(Color.Black)) {
        if (granted) {
            QrCamera { text ->
                val c = FriendLink.parse(text)
                if (c == null) wrong = true else onFound(OpenedCode(c.first, c.second))
            }
            Column(Modifier.fillMaxSize().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically)) {
                Box(Modifier.size(240.dp).border(3.dp, Color.White.copy(alpha = 0.9f), RoundedCornerShape(24.dp)))
                Text(if (wrong) "That’s not a Haltewekker friend code." else "Point the camera at your friend’s code.", color = Color.White, fontWeight = FontWeight.SemiBold,
                    textAlign = TextAlign.Center, modifier = Modifier.clip(CircleShape).background(Color.Black.copy(alpha = 0.6f)).padding(horizontal = 16.dp, vertical = 10.dp))
            }
        } else if (asked) {
            Text("Haltewekker may not use the camera. Allow it in the phone’s settings to scan a friend code, or ask your friend to send their link.",
                color = Color.White, textAlign = TextAlign.Center, modifier = Modifier.align(Alignment.Center).padding(24.dp))
        }
        QuietButton("Cancel", Modifier.align(Alignment.BottomCenter).padding(32.dp), onCancel)
    }
}

@Composable
private fun QrCamera(onCode: (String) -> Unit) {
    val context = LocalContext.current
    val owner = LocalLifecycleOwner.current
    val executor = remember { Executors.newSingleThreadExecutor() }
    var last by remember { mutableStateOf<String?>(null) }
    val main = remember { ContextCompat.getMainExecutor(context) }
    DisposableEffect(Unit) { onDispose { executor.shutdown(); try { ProcessCameraProvider.getInstance(context).get().unbindAll() } catch (_: Exception) {} } }
    AndroidView(factory = { ctx ->
        val view = PreviewView(ctx)
        val future = ProcessCameraProvider.getInstance(ctx)
        future.addListener({
            try {
                val provider = future.get()
                val preview = Preview.Builder().build().also { it.surfaceProvider = view.surfaceProvider }
                val reader = MultiFormatReader().apply { setHints(mapOf(DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE), DecodeHintType.TRY_HARDER to true)) }
                val analysis = ImageAnalysis.Builder().setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST).build()
                analysis.setAnalyzer(executor) { img ->
                    val text = decode(reader, img)
                    img.close()
                    if (text != null) main.execute { if (text != last) { last = text; onCode(text) } }
                }
                provider.unbindAll()
                provider.bindToLifecycle(owner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
            } catch (_: Exception) {}
        }, main)
        view
    }, modifier = Modifier.fillMaxSize())
}

private fun decode(reader: MultiFormatReader, img: ImageProxy): String? = try {
    val plane = img.planes[0]
    val buf = plane.buffer
    val stride = plane.rowStride
    val w = img.width; val h = img.height
    val data = ByteArray(w * h)
    val row = ByteArray(stride)
    buf.rewind()
    for (y in 0 until h) {
        val len = minOf(stride, buf.remaining())
        buf.get(row, 0, len)
        System.arraycopy(row, 0, data, y * w, minOf(w, len))
    }
    val src = PlanarYUVLuminanceSource(data, w, h, 0, 0, w, h, false)
    reader.decodeWithState(BinaryBitmap(HybridBinarizer(src))).text
} catch (_: Exception) { null } finally { reader.reset() }
