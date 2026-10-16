package app.pult.tv

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.SystemClock
import android.view.Surface
import android.view.WindowManager
import java.util.ArrayDeque
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.max
import kotlin.math.roundToInt

/** TV-initiated MediaProjection -> hardware AVC encoder. No screen data saved to disk. */
class ScreenCaptureService : Service() {
    data class Packet(
        val seq: Long, val ptsUs: Long, val flags: Int, val bytes: ByteArray,
        val encodedAtMs: Long,
    )

    companion object {
        const val ACTION_START = "app.pult.tv.screen.START"
        const val ACTION_STOP = "app.pult.tv.screen.STOP"
        const val EXTRA_RESULT = "result"
        const val EXTRA_DATA = "data"
        private const val CHANNEL = "pult_screen_share"
        private const val NOTIFICATION_ID = 39679
        private val packetLock = java.lang.Object()
        private val packetBuffer = ArrayDeque<Packet>()
        private val packetSequence = AtomicLong(0)
        @Volatile private var instance: ScreenCaptureService? = null
        @Volatile var sharing: Boolean = false
            private set
        @Volatile var status: String = "Трансляция выключена"
            private set
        @Volatile var videoWidth: Int = 1280
            private set
        @Volatile var videoHeight: Int = 720
            private set
        @Volatile private var parameterSets: ByteArray? = null
        @Volatile var encoderName: String = "не запущен"
            private set
        @Volatile var actualEncodedFps: Int = 0
            private set

        fun requestKeyFrame() = instance?.requestSyncFrame()
        fun latestSequence(): Long = packetSequence.get()
        fun codecConfig(): ByteArray? = parameterSets?.clone()

        /** Wait for the next access unit; callers maintain their own playback cursor. */
        fun awaitPacket(after: Long, timeoutMs: Long): Packet? {
            synchronized(packetLock) {
                var result = packetBuffer.firstOrNull { it.seq > after }
                if (result != null || !sharing) return result
                packetLock.wait(timeoutMs)
                result = packetBuffer.firstOrNull { it.seq > after }
                return result
            }
        }
    }

    @Volatile private var closing = false
    private var projection: MediaProjection? = null
    private var projectionCallback: MediaProjection.Callback? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var encoder: MediaCodec? = null
    private var inputSurface: Surface? = null
    private var captureThread: HandlerThread? = null
    private var drainThread: Thread? = null
    private val syncLock = Object()

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
            } else startForeground(NOTIFICATION_ID, notification())
            @Suppress("DEPRECATION")
            val consent = if (Build.VERSION.SDK_INT >= 33)
                intent.getParcelableExtra(EXTRA_DATA, Intent::class.java)
            else intent.getParcelableExtra(EXTRA_DATA)
            if (consent == null || intent.getIntExtra(EXTRA_RESULT, 0) != android.app.Activity.RESULT_OK) {
                status = "Android не выдал разрешение на трансляцию"
                stopSelf()
                return START_NOT_STICKY
            }
            setupCapture(intent.getIntExtra(EXTRA_RESULT, 0), consent)
        } catch (e: Exception) {
            status = "Ошибка H.264: ${e.javaClass.simpleName}: ${e.message?.take(100)}"
            stopSelf()
        }
        return START_NOT_STICKY // New Android consent required if the process is killed.
    }

    private fun notification(): Notification {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(NotificationChannel(
            CHANNEL, "Экран X96", NotificationManager.IMPORTANCE_LOW))
        val stopIntent = Intent(this, ScreenCaptureService::class.java).apply { action = ACTION_STOP }
        val stop = PendingIntent.getService(this, 20, stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .setContentTitle("Пульт · Экран X96")
            .setContentText("H.264 · только для сопряжённого телефона в домашней сети")
            .setOngoing(true)
            .addAction(Notification.Action.Builder(
                android.R.drawable.ic_menu_close_clear_cancel, "Остановить", stop).build())
            .build()
    }

    @Suppress("DEPRECATION")
    private fun setupCapture(result: Int, consent: Intent) {
        val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val screen = android.graphics.Point()
        wm.defaultDisplay.getRealSize(screen)
        val scale = minOf(1.0, 1280.0 / max(screen.x, screen.y).coerceAtLeast(1))
        // Use macroblock-aligned dimensions to accommodate older Amlogic codecs.
        val width = (((screen.x * scale).roundToInt() / 16) * 16).coerceAtLeast(16)
        val height = (((screen.y * scale).roundToInt() / 16) * 16).coerceAtLeast(16)
        videoWidth = width
        videoHeight = height
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            // 720p at 30 FPS, intentionally conservative for older Amlogic hardware.
            // 1.6 Mbps CBR-ish rate avoids bursty network congestion on home Wi-Fi.
            setInteger(MediaFormat.KEY_BIT_RATE, 1_600_000)
            setInteger(MediaFormat.KEY_FRAME_RATE, 30)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
        }
        // Prefer a real hardware encoder on Android 10+; if the X96 firmware
        // does not expose one, use the platform AVC encoder as a fallback.
        val hardware = if (Build.VERSION.SDK_INT >= 29) {
            MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.firstOrNull { info ->
                info.isEncoder && info.isHardwareAccelerated &&
                    info.supportedTypes.any { it.equals(MediaFormat.MIMETYPE_VIDEO_AVC, true) }
            }
        } else null
        val codec = if (hardware != null) MediaCodec.createByCodecName(hardware.name)
                    else MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        encoder = codec
        encoderName = codec.name
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        inputSurface = codec.createInputSurface()
        val handlerThread = HandlerThread("PultProjection")
        handlerThread.start()
        captureThread = handlerThread
        val handler = Handler(handlerThread.looper)
        val mediaProjection = (getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager)
            .getMediaProjection(result, consent)
            ?: throw IllegalStateException("MediaProjection unavailable")
        projection = mediaProjection
        val cb = object : MediaProjection.Callback() {
            override fun onStop() {
                status = "Android остановил трансляцию"
                stopSelf()
            }
        }
        projectionCallback = cb
        mediaProjection.registerCallback(cb, handler)
        codec.start()
        virtualDisplay = mediaProjection.createVirtualDisplay("Pult X96 AVC", width, height,
            resources.displayMetrics.densityDpi, DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            inputSurface, null, handler)
        synchronized(packetLock) { packetBuffer.clear(); packetLock.notifyAll() }
        parameterSets = null
        closing = false
        sharing = true
        instance = this
        actualEncodedFps = 0
        status = "H.264 · ${width}×$height · ${codec.name}"
        drainThread = Thread({ drain(codec) }, "PultH264Encoder").also { it.start() }
    }

    private fun requestSyncFrame() {
        synchronized(syncLock) {
            try {
                encoder?.setParameters(Bundle().apply {
                    putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
                })
            } catch (_: Exception) { /* Some vendor encoders request IDRs only on schedule. */ }
        }
    }

    private fun drain(codec: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        var fpsWindowMs = SystemClock.elapsedRealtime()
        var fpsSamples = 0
        while (sharing && !closing) {
            try {
                when (val index = codec.dequeueOutputBuffer(info, 12000)) {
                    MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val f = codec.outputFormat
                        // Android encoders expose the SPS/PPS here even if there is no
                        // BUFFER_FLAG_CODEC_CONFIG output buffer.
                        val sps = f.getByteBuffer("csd-0")
                        val pps = f.getByteBuffer("csd-1")
                        if (sps != null) {
                            val first = ByteArray(sps.remaining()).also { sps.get(it) }
                            val second = if (pps != null)
                                ByteArray(pps.remaining()).also { pps.get(it) }
                            else ByteArray(0)
                            parameterSets = first + second
                        }
                    }
                    in 0..Int.MAX_VALUE -> {
                        val buffer = codec.getOutputBuffer(index)
                        if (buffer != null && info.size > 0) {
                            buffer.position(info.offset)
                            buffer.limit(info.offset + info.size)
                            val data = ByteArray(info.size)
                            buffer.get(data)
                            if ((info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
                                parameterSets = data
                            } else {
                                val packet = Packet(packetSequence.incrementAndGet(),
                                    info.presentationTimeUs, info.flags, data,
                                    SystemClock.elapsedRealtime())
                                fpsSamples++
                                val now = SystemClock.elapsedRealtime()
                                if (now - fpsWindowMs >= 2000L) {
                                    actualEncodedFps = (fpsSamples * 1000L /
                                        (now - fpsWindowMs).coerceAtLeast(1L)).toInt()
                                    fpsSamples = 0
                                    fpsWindowMs = now
                                }
                                synchronized(packetLock) {
                                    packetBuffer.addLast(packet)
                                    // Retain enough for keyframe recovery, not several seconds of stale video.
                                    while (packetBuffer.size > 12) packetBuffer.removeFirst()
                                    packetLock.notifyAll()
                                }
                            }
                        }
                        codec.releaseOutputBuffer(index, false)
                    }
                }
            } catch (_: Exception) {
                if (!closing) status = "Сбой аппаратного кодирования H.264"
                break
            }
        }
    }

    override fun onDestroy() {
        closing = true
        sharing = false
        instance = null
        synchronized(packetLock) { packetBuffer.clear(); packetLock.notifyAll() }
        virtualDisplay?.release(); virtualDisplay = null
        val mediaProjection = projection; projection = null
        val callback = projectionCallback; projectionCallback = null
        if (mediaProjection != null) {
            if (callback != null) mediaProjection.unregisterCallback(callback)
            try { mediaProjection.stop() } catch (_: Exception) { }
        }
        try { drainThread?.join(600) } catch (_: InterruptedException) { }
        drainThread = null
        synchronized(syncLock) {
            try { encoder?.stop() } catch (_: Exception) { }
            try { encoder?.release() } catch (_: Exception) { }
            encoder = null
        }
        inputSurface?.release(); inputSurface = null
        captureThread?.quitSafely(); captureThread = null
        parameterSets = null
        actualEncodedFps = 0
        if (!status.startsWith("Ошибка H.264") && !status.startsWith("Android остановил"))
            status = "Трансляция выключена"
        super.onDestroy()
    }
}
