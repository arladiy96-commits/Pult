package app.pult.tv

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.SystemClock
import android.view.WindowManager
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Explicit, TV-initiated MediaProjection capture. Frames live ONLY in memory
 * and are served to an already-paired local TLS client on request.
 *
 * Initial compatibility mode: 720p JPEG, capped at ~8 fps. This avoids adding
 * hardware codec dependencies before testing the actual X96 firmware.
 */
class ScreenCaptureService : Service() {
    data class Frame(val sequence: Long, val width: Int, val height: Int, val jpeg: ByteArray)

    companion object {
        private const val CHANNEL = "pult_screen_share"
        private const val NOTIFICATION_ID = 39679
        const val ACTION_START = "app.pult.tv.screen.START"
        const val ACTION_STOP = "app.pult.tv.screen.STOP"
        const val EXTRA_RESULT = "result"
        const val EXTRA_DATA = "data"

        @Volatile var sharing = false
            private set
        @Volatile var status = "Трансляция выключена"
            private set
        @Volatile var latestFrame: Frame? = null
            private set
    }

    private val counter = AtomicLong()
    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    private var projection: MediaProjection? = null
    private var projectionCallback: MediaProjection.Callback? = null
    private var display: VirtualDisplay? = null
    private var reader: ImageReader? = null
    private var lastFrameAt = 0L
    private var closing = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (intent?.action != ACTION_START || sharing) return START_NOT_STICKY
        try {
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(NOTIFICATION_ID, notification(),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
            } else {
                startForeground(NOTIFICATION_ID, notification())
            }
            @Suppress("DEPRECATION")
            val data = if (Build.VERSION.SDK_INT >= 33) {
                intent.getParcelableExtra(EXTRA_DATA, Intent::class.java)
            } else intent.getParcelableExtra(EXTRA_DATA)
            val result = intent.getIntExtra(EXTRA_RESULT, 0)
            if (data == null || result != android.app.Activity.RESULT_OK) {
                status = "Не получено разрешение на захват экрана"
                stopSelf()
                return START_NOT_STICKY
            }
            startCapture(result, data)
        } catch (e: Exception) {
            status = "Ошибка трансляции: ${e.javaClass.simpleName}: ${e.message?.take(90)}"
            stopSelf()
        }
        return START_NOT_STICKY // Consent cannot be reused after process death.
    }

    private fun notification(): Notification {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(NotificationChannel(
            CHANNEL, "Трансляция экрана X96", NotificationManager.IMPORTANCE_LOW
        ))
        val stopIntent = Intent(this, ScreenCaptureService::class.java).apply { action = ACTION_STOP }
        val stop = PendingIntent.getService(this, 20, stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .setContentTitle("Пульт · Трансляция экрана")
            .setContentText("Экран X96 доступен сопряжённому телефону в домашней сети")
            .setOngoing(true)
            .addAction(Notification.Action.Builder(
                android.R.drawable.ic_menu_close_clear_cancel, "Остановить", stop
            ).build())
            .build()
    }

    @Suppress("DEPRECATION")
    private fun startCapture(result: Int, consent: Intent) {
        val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val screen = android.graphics.Point()
        wm.defaultDisplay.getRealSize(screen)
        val maxSide = max(screen.x, screen.y).coerceAtLeast(1)
        val factor = minOf(1.0, 1280.0 / maxSide)
        val width = ((screen.x * factor).roundToInt() / 2 * 2).coerceAtLeast(2)
        val height = ((screen.y * factor).roundToInt() / 2 * 2).coerceAtLeast(2)
        val dpi = resources.displayMetrics.densityDpi

        val t = HandlerThread("PultScreenCapture").also { it.start() }
        thread = t
        val h = Handler(t.looper)
        handler = h
        val p = (getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager)
            .getMediaProjection(result, consent)
            ?: throw IllegalStateException("Android не выдал доступ к экрану")
        projection = p
        val cb = object : MediaProjection.Callback() {
            override fun onStop() {
                status = "Android остановил трансляцию экрана"
                stopSelf()
            }
        }
        projectionCallback = cb
        p.registerCallback(cb, h)

        val images = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 3)
        reader = images
        images.setOnImageAvailableListener({ source ->
            val image = try { source.acquireLatestImage() } catch (_: Exception) { null }
            if (image == null) return@setOnImageAvailableListener
            try {
                val now = SystemClock.elapsedRealtime()
                if (now - lastFrameAt < 120L) return@setOnImageAvailableListener
                lastFrameAt = now
                val plane = image.planes.firstOrNull() ?: return@setOnImageAvailableListener
                val pixelStride = plane.pixelStride
                val rowStride = plane.rowStride
                if (pixelStride != 4 || rowStride <= 0) return@setOnImageAvailableListener
                // Vendor GPUs often pad each row. Copy visible pixels only,
                // including the final row (which need not include row padding).
                val packed = ByteBuffer.allocate(width * height * pixelStride)
                val sourceBuffer = plane.buffer
                val row = ByteArray(width * pixelStride)
                for (y in 0 until height) {
                    sourceBuffer.position(y * rowStride)
                    sourceBuffer.get(row)
                    packed.put(row)
                }
                packed.flip()
                val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                try {
                    bitmap.copyPixelsFromBuffer(packed)
                    val buffer = ByteArrayOutputStream(90_000)
                    if (bitmap.compress(Bitmap.CompressFormat.JPEG, 57, buffer)) {
                        latestFrame = Frame(counter.incrementAndGet(), width, height, buffer.toByteArray())
                    }
                } finally { bitmap.recycle() }
            } catch (_: Exception) {
                // Some vendor ROMs return unsupported image strides during rotations.
                // Keep capture alive; the next image may be valid.
            } finally { image.close() }
        }, h)
        display = p.createVirtualDisplay("Pult X96 Screen", width, height, dpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, images.surface, null, h)
        sharing = true
        status = "Экран передаётся · ${width}×$height · до 8 кадров/с"
    }

    override fun onDestroy() {
        if (!closing) {
            closing = true
            sharing = false
            latestFrame = null
            reader?.setOnImageAvailableListener(null, null)
            display?.release()
            display = null
            reader?.close()
            reader = null
            val p = projection
            projection = null
            val cb = projectionCallback
            projectionCallback = null
            if (p != null) {
                if (cb != null) p.unregisterCallback(cb)
                p.stop()
            }
            thread?.quitSafely()
            thread = null
            handler = null
            if (!status.startsWith("Ошибка трансляции") &&
                !status.startsWith("Android остановил")) {
                status = "Трансляция выключена"
            }
        }
        super.onDestroy()
    }
}
