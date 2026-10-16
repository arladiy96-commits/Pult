package app.pult.tv

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.os.SystemClock
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.BufferedWriter
import java.io.DataOutputStream
import java.io.BufferedOutputStream
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.SocketException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLSocket

/**
 * Line-delimited JSON over TLS 1.2/1.3, TCP 39678.
 * Each connection must start with pair(PIN) or auth(token). The pinned device
 * certificate prevents trusting another TV when the phone reconnects.
 */
class CompanionServer(context: Context, private val accessibility: TvAccessibilityService) {
    companion object {
        const val PORT = 39678
        @Volatile var status = "Служба не запущена"
            private set
        // Visible locally on the TV: we need to distinguish TLS failure from
        // connectivity or expired pairing. Never logs the PIN or auth token.
        @Volatile var connectionDiagnostic = "Подключений пока не было"
            private set
    }
    private val pairing = CompanionState.store(context)
    private val catalog = AppCatalog(context)
    private val main = Handler(Looper.getMainLooper())
    private val executor = Executors.newCachedThreadPool()
    @Volatile private var running = false
    @Volatile private var listener: SSLServerSocket? = null

    fun start() {
        running = true
        executor.execute {
            try {
                val ss = SecureTransport.serverSocket(PORT)
                listener = ss
                status = "Работает · порт $PORT · TLS"
                while (running) {
                    val client = ss.accept() as SSLSocket
                    executor.execute { acceptClient(client) }
                }
            } catch (e: Exception) {
                if (running) {
                    Log.e("PultTV", "Cannot start server", e)
                    status = "Ошибка сервера: ${e.javaClass.simpleName}"
                }
            }
        }
    }

    fun stop() {
        running = false
        try { listener?.close() } catch (_: Exception) { }
        executor.shutdownNow()
        status = "Служба остановлена"
    }

    private fun acceptClient(client: SSLSocket) {
        try {
            client.use { socket ->
                // Reject clients outside RFC1918 local LAN (no Internet remote control).
                if (!socket.inetAddress.isSiteLocalAddress && !socket.inetAddress.isLoopbackAddress) {
                    connectionDiagnostic = "Соединение отклонено: не локальная сеть"
                    return
                }
                socket.soTimeout = 15000
                try {
                    socket.startHandshake()
                    connectionDiagnostic = "TLS: соединение установлено"
                } catch (e: Exception) {
                    connectionDiagnostic = "Ошибка TLS: ${e.javaClass.simpleName}: ${e.message?.take(160) ?: "неизвестная"}"
                    Log.e("PultTV", "TLS handshake failed", e)
                    return
                }
                val input = BufferedReader(InputStreamReader(socket.inputStream, Charsets.UTF_8))
                val output = BufferedWriter(OutputStreamWriter(socket.outputStream, Charsets.UTF_8))
                val first = readRequest(input) ?: return
                val cmd = first.optString("cmd")
                var sessionToken = ""
                val authorized = when (cmd) {
                    "pair" -> {
                        val token = pairing.pair(first.optString("pin"))
                        send(output, if (token == null) fail("Неверный или просроченный код")
                            else JSONObject().put("ok", true).put("token", token)
                                .put("version", 1))
                        if (token != null) sessionToken = token
                        token != null
                    }
                    "auth" -> {
                        val claimedToken = first.optString("token")
                        val valid = pairing.authenticated(claimedToken)
                        if (valid) sessionToken = claimedToken
                        send(output, if (valid) JSONObject().put("ok", true).put("version", 1)
                            else fail("Телефон не сопряжён"))
                        valid
                    }
                    else -> false
                }
                if (!authorized) return
                // Keep the authenticated LAN session alive while the phone is in
                // background. The phone rechecks it when returning to foreground.
                socket.soTimeout = 0
                socket.keepAlive = true
                socket.tcpNoDelay = true
                while (running) {
                    val req = readRequest(input) ?: break
                    if (!pairing.authenticated(sessionToken)) {
                        send(output, fail("Доступ отозван. Выполните новое сопряжение"))
                        break
                    }
                    // Video lives on its own authenticated TLS connection. Do not
                    // block control gestures behind large media packets.
                    if (req.optString("cmd") == "video_stream") {
                        if (!ScreenCaptureService.sharing) {
                            send(output, fail("На приставке включите трансляцию экрана"))
                        } else {
                            send(output, JSONObject().put("ok", true)
                                .put("codec", "avc1").put("width", ScreenCaptureService.videoWidth)
                                .put("height", ScreenCaptureService.videoHeight)
                                .put("packetStats", req.optBoolean("stats", false)))
                            streamAvc(socket, req.optBoolean("ack", false),
                                req.optBoolean("stats", false))
                        }
                        return
                    }
                    val reply = try { execute(req) } catch (e: Exception) {
                        fail("Команда не выполнена: ${e.javaClass.simpleName}")
                    }
                    send(output, reply)
                }
            }
        } catch (e: Exception) {
            if (running && e !is SocketException) Log.d("PultTV", "Client disconnected: ${e.message}")
        }
    }

    private fun execute(req: JSONObject): JSONObject {
        return when (req.optString("cmd")) {
            "ping" -> JSONObject().put("ok", true).put("version", 1)
            "apps" -> JSONObject().put("ok", true).put("apps", catalog.apps())
            "screen_info" -> JSONObject().put("ok", true)
                .put("sharing", ScreenCaptureService.sharing)
                .put("status", ScreenCaptureService.status)
                .put("encoder", ScreenCaptureService.encoderName)
                .put("fps", ScreenCaptureService.actualEncodedFps)
            "screen_frame" -> fail("Обновите пульт: трансляция использует H.264")
            "launch" -> {
                val pkg = req.optString("package")
                onMain {
                    if (catalog.launch(pkg)) JSONObject().put("ok", true)
                    else fail("Не удалось открыть приложение")
                }
            }
            else -> onMain { accessibility.handle(req) }
        }
    }

    /** AVC access units. New phone clients ACK each packet to prevent TCP/video backlog.
     * Older clients can still connect without flow control, so rollout is safe.
     */
    private fun streamAvc(socket: SSLSocket, flowControl: Boolean,
            telemetry: Boolean) {
        socket.tcpNoDelay = true
        if (flowControl) {
            socket.sendBufferSize = 64 * 1024
            socket.soTimeout = 4000
        } else {
            socket.soTimeout = 0
        }
        val output = DataOutputStream(BufferedOutputStream(socket.outputStream, 32 * 1024))
        // JSON authentication has finished. Flow-control bytes start only after
        // this server has sent the first config/frame, so the JSON reader cannot
        // prefetch an ACK accidentally.
        val acknowledgements = if (flowControl) socket.inputStream else null
        var cursor = ScreenCaptureService.latestSequence()
        var waitingKeyframe = true
        var lastSyncAt = 0L
        while (running && ScreenCaptureService.sharing) {
            // Never deliver seconds-old pictures. Frames between IDRs depend on
            // each other, so dropping arbitrary P-frames would corrupt playback.
            // Jump to live edge and request an IDR instead.
            if (ScreenCaptureService.latestSequence() - cursor > 6L) {
                cursor = ScreenCaptureService.latestSequence()
                waitingKeyframe = true
            }
            val packet = ScreenCaptureService.awaitPacket(cursor, 450) ?: continue
            if (!waitingKeyframe && packet.seq != cursor + 1L) waitingKeyframe = true
            cursor = packet.seq
            // Even if sequence numbers are contiguous, a stalled encoder or
            // slow socket must not show yesterday's frame after the user taps.
            if (SystemClock.elapsedRealtime() - packet.encodedAtMs > 200L) {
                cursor = ScreenCaptureService.latestSequence()
                waitingKeyframe = true
                continue
            }
            if (waitingKeyframe) {
                val now = android.os.SystemClock.elapsedRealtime()
                if (now - lastSyncAt > 450L) {
                    ScreenCaptureService.requestKeyFrame()
                    lastSyncAt = now
                }
                if ((packet.flags and android.media.MediaCodec.BUFFER_FLAG_KEY_FRAME) == 0) continue
                val config = ScreenCaptureService.codecConfig() ?: continue
                if (!writePacket(output, config, 0L,
                        android.media.MediaCodec.BUFFER_FLAG_CODEC_CONFIG,
                        telemetry, 0)) continue
                output.flush()
                if (flowControl && acknowledgements?.read() != 0x06) return
                waitingKeyframe = false
            }
            val pendingMs = (SystemClock.elapsedRealtime() - packet.encodedAtMs)
                .coerceIn(0L, 60000L).toInt()
            if (!writePacket(output, packet.bytes, packet.ptsUs, packet.flags,
                    telemetry, pendingMs)) continue
            output.flush()
            if (flowControl && acknowledgements?.read() != 0x06) return
        }
    }

    private fun writePacket(output: DataOutputStream, bytes: ByteArray,
            pts: Long, flags: Int, telemetry: Boolean, encodedWaitMs: Int): Boolean {
        if (bytes.isEmpty() || bytes.size > 2_000_000) return false
        output.writeInt(bytes.size)
        output.writeLong(pts)
        output.writeInt(flags)
        // Optional protocol extension: only clients explicitly requesting
        // stats expect the fourth integer in each packet header.
        if (telemetry) output.writeInt(encodedWaitMs)
        output.write(bytes)
        return true
    }

    private fun onMain(action: () -> JSONObject): JSONObject {
        val result = AtomicReference<JSONObject>(fail("Тайм-аут"))
        val finished = CountDownLatch(1)
        main.post {
            try { result.set(action()) } catch (e: Exception) {
                result.set(fail("Ошибка Android: ${e.javaClass.simpleName}"))
            } finally { finished.countDown() }
        }
        return if (finished.await(5, TimeUnit.SECONDS)) result.get() else fail("Тайм-аут Android")
    }

    private fun readRequest(input: BufferedReader): JSONObject? {
        // Limit requests to 16 KiB without unbounded readLine() allocation.
        val builder = StringBuilder()
        while (builder.length < 16384) {
            val value = input.read()
            if (value == -1) return null
            if (value == '\n'.code) break
            if (value != '\r'.code) builder.append(value.toChar())
        }
        if (builder.isEmpty() || builder.length >= 16384) return null
        return try { JSONObject(builder.toString()) } catch (_: Exception) { null }
    }

    private fun send(output: BufferedWriter, reply: JSONObject) {
        output.write(reply.toString())
        output.write("\n")
        output.flush()
    }

    private fun fail(message: String) = JSONObject().put("ok", false).put("error", message)
}
