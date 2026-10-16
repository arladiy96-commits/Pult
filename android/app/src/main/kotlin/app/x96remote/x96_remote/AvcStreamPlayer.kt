package app.x96remote.x96_remote

import android.media.MediaCodec
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
        writeJson(JSONObject().put("cmd", "video_stream"))
        val header = JSONObject(readLineLimited(input))
        if (!header.optBoolean("ok")) throw IllegalStateException(header.optString("error", "Нет видео"))
        lastWidth = header.getInt("width")
        lastHeight = header.getInt("height")
        require(lastWidth in 16..3840 && lastHeight in 16..2160) { "Недопустимое разрешение" }
        texture.surfaceTexture().setDefaultBufferSize(lastWidth, lastHeight)
        report("Подключение H.264 · ${lastWidth}×$lastHeight")
        connection.soTimeout = 40000
        var initialized = false
        while (!stopped) {
            val length = input.readInt()
            val ptsUs = input.readLong()
            val flags = input.readInt()
            if (length !in 1..2_000_000) throw IllegalStateException("Некорректный видеопакет")
            val bytes = ByteArray(length)
            input.readFully(bytes)
            if ((flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
                initializeDecoder(bytes)
                initialized = true
                report("Прямая трансляция H.264 · ${lastWidth}×$lastHeight")
                continue
            }
            if (initialized) queueFrame(bytes, ptsUs, flags)
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
            decoder.configure(format, surface, null, 0)
            decoder.start()
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
        var index = -1
        for (attempt in 0 until 12) {
            drainOutput(decoder)
            index = decoder.dequeueInputBuffer(15000)
            if (index >= 0) break
        }
        if (index < 0) throw IllegalStateException("Видеодекодер перегружен")
        val buffer = decoder.getInputBuffer(index) ?: throw IllegalStateException("Нет входного буфера")
        buffer.clear()
        if (data.size > buffer.remaining()) throw IllegalStateException("Слишком большой кадр")
        buffer.put(data)
        decoder.queueInputBuffer(index, 0, data.size, ptsUs, flags and MediaCodec.BUFFER_FLAG_KEY_FRAME)
        drainOutput(decoder)
    }

    private fun drainOutput(decoder: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        while (true) {
            val out = decoder.dequeueOutputBuffer(info, 0)
            if (out >= 0) decoder.releaseOutputBuffer(out, true)
            else break
        }
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
