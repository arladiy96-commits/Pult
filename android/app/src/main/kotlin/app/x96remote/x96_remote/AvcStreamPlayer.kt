package app.x96remote.x96_remote

import android.media.MediaCodec
import android.os.Build
import android.os.SystemClock
import android.media.MediaFormat
import android.os.Handler
import android.os.Looper
import android.view.Surface
import io.flutter.embedding.engine.renderer.FlutterRenderer
import io.flutter.view.TextureRegistry
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.net.SocketException
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.cert.X509Certificate
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager

/** Dedicated certificate-pinned TLS H.264 receiver and Android hardware decoder. */
internal class AvcStreamPlayer(
    renderer: FlutterRenderer,
    private val host: String,
    private val fingerprint: String,
    private val token: String,
    private val onStatus: (String, Int, Int) -> Unit,
) {
    private val main = Handler(Looper.getMainLooper())
    private val texture: TextureRegistry.SurfaceTextureEntry = renderer.createSurfaceTexture()
    private val surface = Surface(texture.surfaceTexture())
    val textureId: Long = texture.id()
    @Volatile private var stopped = false
    @Volatile private var socket: SSLSocket? = null
    private var codec: MediaCodec? = null
    private var worker: Thread? = null
    private var lastWidth = 1280
    private var lastHeight = 720
    private var countReceived = 0
    private var countDisplayed = 0
    private var queuedSamples = 0
    private var outputSamples = 0
    private var metricsStartMs = SystemClock.elapsedRealtime()
    private var lastOutputMs = SystemClock.elapsedRealtime()
    private var serverQueueMs = 0
    private var decoderName = "MediaCodec"

    fun start() {
        worker = Thread({ run() }, "PultAvcReceiver").also { it.start() }
    }

    private fun report(message: String, w: Int = lastWidth, h: Int = lastHeight) {
        if (!stopped) main.post { if (!stopped) onStatus(message, w, h) }
    }

    private fun run() {
        while (!stopped) {
            try {
                playConnection()
            } catch (e: Exception) {
                if (!stopped) report("Восстанавливаю видеосвязь: ${e.message?.take(90) ?: e.javaClass.simpleName}")
            } finally {
                socket?.closeQuietly()
                socket = null
                releaseCodec()
            }
            if (!stopped) try { Thread.sleep(1500) } catch (_: InterruptedException) { }
        }
    }

    private fun playConnection() {
        val ctx = SSLContext.getInstance("TLS")
        // Trust is established ONLY by the device SHA-256 pinned during pairing.
        // The token is sent after the handshake and exact certificate comparison.
        val pinned = object : X509TrustManager {
            override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) {}
            override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {}
            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
        }
        ctx.init(null, arrayOf<TrustManager>(pinned), SecureRandom())
        val connection = ctx.socketFactory.createSocket(host, 39678) as SSLSocket
        socket = connection
        connection.soTimeout = 10000
        connection.tcpNoDelay = true
        connection.startHandshake()
        val certificate = connection.session.peerCertificates.first().encoded
        val actual = MessageDigest.getInstance("SHA-256").digest(certificate)
            .joinToString("") { "%02X".format(it.toInt() and 0xff) }
        if (actual != fingerprint.replace(":", "").uppercase())
            throw SecurityException("Изменился сертификат приставки")
        val input = DataInputStream(BufferedInputStream(connection.inputStream, 64 * 1024))
        val output = BufferedOutputStream(connection.outputStream)
        fun writeJson(json: JSONObject) {
            output.write((json.toString() + "\n").toByteArray(Charsets.UTF_8))
            output.flush()
        }
        writeJson(JSONObject().put("cmd", "auth").put("token", token))
        val auth = JSONObject(readLineLimited(input))
        if (!auth.optBoolean("ok")) throw SecurityException(auth.optString("error", "Нет авторизации"))
        // Per-frame acknowledgements keep at most one in-flight AVC access unit.
        // The TV will skip to a new IDR when decoder/network throughput drops.
        writeJson(JSONObject().put("cmd", "video_stream")
            .put("ack", true).put("stats", true))
        val header = JSONObject(readLineLimited(input))
        if (!header.optBoolean("ok")) throw IllegalStateException(header.optString("error", "Нет видео"))
        lastWidth = header.getInt("width")
        lastHeight = header.getInt("height")
        // Older installed TV companions have no telemetry header extension.
        // Negotiate per-packet stats before reading the optional integer.
        val packetStats = header.optBoolean("packetStats", false)
        require(lastWidth in 16..3840 && lastHeight in 16..2160) { "Недопустимое разрешение" }
        texture.surfaceTexture().setDefaultBufferSize(lastWidth, lastHeight)
        report("Подключение H.264 · ${lastWidth}×$lastHeight")
        connection.soTimeout = 40000
        var initialized = false
        countReceived = 0
        countDisplayed = 0
        queuedSamples = 0
        outputSamples = 0
        metricsStartMs = SystemClock.elapsedRealtime()
        lastOutputMs = metricsStartMs
        while (!stopped) {
            val length = input.readInt()
            val ptsUs = input.readLong()
            val flags = input.readInt()
            serverQueueMs = if (packetStats) input.readInt().coerceAtLeast(0) else 0
            if (length !in 1..2_000_000) throw IllegalStateException("Некорректный видеопакет")
            val bytes = ByteArray(length)
            input.readFully(bytes)
            if ((flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
                initializeDecoder(bytes)
                initialized = true
                report("H.264 · $decoderName · ${lastWidth}×$lastHeight")
            } else if (initialized) {
                queueFrame(bytes, ptsUs, flags)
                countReceived++
                showMetricsIfDue()
            }
            // Tell the TV that this packet has been consumed by the decoder.
            // Unlike uncontrolled TCP writes, this cannot build a multi-second queue.
            output.write(0x06)
            output.flush()
        }
    }

    private fun initializeDecoder(parameters: ByteArray) {
        releaseCodec()
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC,
            lastWidth, lastHeight)
        val units = splitAnnexB(parameters)
        val sps = units.firstOrNull { it.size > 4 && (it[4].toInt() and 31) == 7 }
        val pps = units.firstOrNull { it.size > 4 && (it[4].toInt() and 31) == 8 }
        if (sps != null && pps != null) {
            format.setByteBuffer("csd-0", ByteBuffer.wrap(sps))
            format.setByteBuffer("csd-1", ByteBuffer.wrap(pps))
        } else {
            // Fallback for codecs providing joined SPS/PPS as one config blob.
            format.setByteBuffer("csd-0", ByteBuffer.wrap(parameters))
        }
        val decoder = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        try {
            // Supported on many Android 11+ decoders. If the vendor codec
            // rejects it, fall back to the exact same format without the hint.
            val lowLatencySupported = Build.VERSION.SDK_INT >= 30 && try {
                decoder.codecInfo.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC)
                    .isFeatureSupported("low-latency")
            } catch (_: Exception) { false }
            if (lowLatencySupported) format.setInteger("low-latency", 1)
            try {
                decoder.configure(format, surface, null, 0)
            } catch (first: Exception) {
                if (!lowLatencySupported) throw first
                decoder.reset()
                format.removeKey("low-latency")
                decoder.configure(format, surface, null, 0)
            }
            decoder.start()
            decoderName = decoder.name
            codec = decoder
        } catch (e: Exception) {
            decoder.release()
            throw e
        }
    }

    private fun splitAnnexB(data: ByteArray): List<ByteArray> {
        val starts = mutableListOf<Pair<Int, Int>>()
        var i = 0
        while (i < data.size - 3) {
            val len = when {
                data[i] == 0.toByte() && data[i+1] == 0.toByte() &&
                    data[i+2] == 0.toByte() && data[i+3] == 1.toByte() -> 4
                data[i] == 0.toByte() && data[i+1] == 0.toByte() &&
                    data[i+2] == 1.toByte() -> 3
                else -> 0
            }
            if (len > 0) { starts.add(i to len); i += len } else i++
        }
        return starts.mapIndexed { index, (offset, len) ->
            val end = if (index + 1 < starts.size) starts[index+1].first else data.size
            byteArrayOf(0, 0, 0, 1) + data.copyOfRange(offset + len, end)
        }
    }

    private fun queueFrame(data: ByteArray, ptsUs: Long, flags: Int) {
        val decoder = codec ?: return
        drainOutput(decoder)
        // Previous version could wait 12 × 15 ms per frame: while waiting,
        // the network accumulated older pictures. Cap total waiting instead.
        var index = decoder.dequeueInputBuffer(4000)
        if (index < 0) {
            drainOutput(decoder)
            index = decoder.dequeueInputBuffer(4000)
        }
        if (index < 0) throw IllegalStateException("Декодер отстаёт: новое подключение к живому кадру")
        val buffer = decoder.getInputBuffer(index) ?: throw IllegalStateException("Нет входного буфера")
        buffer.clear()
        if (data.size > buffer.remaining()) throw IllegalStateException("Слишком большой кадр")
        buffer.put(data)
        decoder.queueInputBuffer(index, 0, data.size, ptsUs,
            flags and MediaCodec.BUFFER_FLAG_KEY_FRAME)
        queuedSamples++
        drainOutput(decoder)
        // This should rarely happen: decoder output usually trails 2-4
        // input samples. If it stalls instead of keeping up, reconnect at
        // the next IDR rather than replay seconds of delayed pictures.
        if (queuedSamples - outputSamples > 12 &&
            SystemClock.elapsedRealtime() - lastOutputMs > 650L) {
            throw IllegalStateException("Декодер не успевает, синхронизация с новым кадром")
        }
    }

    /** Drop superseded decoded output frames; render only the freshest one. */
    private fun drainOutput(decoder: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        var newest = -1
        var count = 0
        while (count++ < 32) {
            val out = decoder.dequeueOutputBuffer(info, 0)
            if (out < 0) break
            if (newest >= 0) decoder.releaseOutputBuffer(newest, false)
            newest = out
            outputSamples++
        }
        if (newest >= 0) {
            decoder.releaseOutputBuffer(newest, true)
            countDisplayed++
            lastOutputMs = SystemClock.elapsedRealtime()
        }
    }

    private fun showMetricsIfDue() {
        val now = SystemClock.elapsedRealtime()
        val elapsed = now - metricsStartMs
        if (elapsed < 2000L) return
        val receivedFps = (countReceived * 1000L / elapsed).toInt()
        val displayedFps = (countDisplayed * 1000L / elapsed).toInt()
        // "Очередь TV" measures time after encoding until network write,
        // NOT capture-to-display latency; the two clocks are independent.
        report("$decoderName · $receivedFps вх./$displayedFps вывод FPS · " +
            "очередь X96 ${serverQueueMs}мс")
        countReceived = 0
        countDisplayed = 0
        metricsStartMs = now
    }

    private fun readLineLimited(input: DataInputStream): String {
        val buf = java.io.ByteArrayOutputStream(512)
        while (buf.size() < 8192) {
            val c = input.read()
            if (c == -1) throw SocketException("Приставка закрыла соединение")
            if (c == 10) return buf.toString("UTF-8")
            if (c != 13) buf.write(c)
        }
        throw IllegalStateException("Слишком длинный ответ приставки")
    }

    private fun releaseCodec() {
        val decoder = codec
        codec = null
        if (decoder != null) {
            try { decoder.stop() } catch (_: Exception) { }
            try { decoder.release() } catch (_: Exception) { }
        }
    }

    fun stop() {
        if (stopped) return
        stopped = true
        socket?.closeQuietly()
        worker?.interrupt()
        // Receiver can still be decoding: surface is released only after worker exit.
        Thread({
            try { worker?.join(1500) } catch (_: InterruptedException) { }
            releaseCodec()
            main.post { surface.release(); texture.release() }
        }, "PultAvcDispose").start()
    }

    private fun SSLSocket.closeQuietly() {
        try { close() } catch (_: Exception) { }
    }
}
