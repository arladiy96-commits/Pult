package app.pult.tv

import android.content.Context
import android.media.MediaCodec
import android.os.SystemClock
import android.util.Log
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.security.SecureRandom
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import android.util.Base64

/**
 * Local-only, dependency-free HTTP UI for Safari. Deliberately separate from
 * the pinned TLS protocol used by the Android Flutter client.
 *
 * IMPORTANT: This endpoint is plain HTTP. Only enable on a trusted home Wi-Fi;
 * PINs, cookies and control commands cannot be protected against a LAN sniffer.
 * No third-party assets, public binding service or remote Internet routing.
 */
class WebRemoteServer(
    private val context: Context,
    private val pairing: PairingStore,
    private val command: (JSONObject) -> JSONObject,
) {
    companion object {
        const val PORT = 8088
        @Volatile var status = "Не запущен"
            private set
        private const val COOKIE = "pult_web"
        private const val MAX_BODY = 8192
        private const val SESSION_IDLE_MS = 12L * 60L * 60L * 1000L
        private val ALLOWED_COMMANDS = setOf(
            "ping", "apps", "screen_info", "launch", "key", "move", "tap",
            "long_press", "scroll", "drag_start", "drag_move", "drag_end",
            "hide_cursor", "screen_tap", "screen_long", "screen_swipe",
            "screen_scroll", "text", "delete"
        )
    }

    private val pool = Executors.newFixedThreadPool(12)
    private val random = SecureRandom()
    private val sessions = ConcurrentHashMap<String, Long>()
    private val liveStreams = AtomicInteger(0)
    @Volatile private var running = false
    @Volatile private var listener: ServerSocket? = null
    private var revokedVersion: Long = pairing.webRevocationVersion()

    fun start() {
        if (running) return
        running = true
        pool.execute {
            try {
                val server = ServerSocket(PORT).apply { reuseAddress = true }
                listener = server
                status = "Веб-пульт: http://IP:$PORT"
                while (running) {
                    val socket = server.accept()
                    pool.execute { handle(socket) }
                }
            } catch (e: Exception) {
                if (running) {
                    status = "Ошибка веб-сервера: ${e.javaClass.simpleName}"
                    Log.e("PultWeb", "Web server failed", e)
                }
            }
        }
    }

    fun stop() {
        running = false
        try { listener?.close() } catch (_: Exception) { }
        listener = null
        sessions.clear()
        pool.shutdownNow()
        status = "Веб-пульт остановлен"
    }

    private fun handle(client: Socket) {
        try {
            client.use { socket ->
                if (!socket.inetAddress.isSiteLocalAddress && !socket.inetAddress.isLoopbackAddress) return
                socket.soTimeout = 10_000
                socket.tcpNoDelay = true
                socket.sendBufferSize = 64 * 1024
                val input = BufferedInputStream(socket.getInputStream())
                val output = BufferedOutputStream(socket.getOutputStream())
                val requestLine = readLine(input, 2048) ?: return
                val match = Regex("^(GET|POST) (/[^ ?]*)(?:\\?[^ ]*)? HTTP/1\\.[01]$").matchEntire(requestLine)
                    ?: return sendJson(output, 400, error("Некорректный запрос"))
                val (method, path) = match.destructured
                val headers = mutableMapOf<String, String>()
                var read = 0
                while (true) {
                    val line = readLine(input, 4096) ?: return
                    read += line.length
                    if (read > 16384) return sendJson(output, 431, error("Слишком много заголовков"))
                    if (line.isEmpty()) break
                    val index = line.indexOf(':')
                    if (index < 1) return
                    headers[line.substring(0, index).lowercase()] = line.substring(index + 1).trim()
                }
                // Numeric LAN IPv4 host only: avoids Host-header DNS rebinding.
                val expectedHost = "${socket.localAddress.hostAddress}:$PORT"
                val host = headers["host"] ?: return
                if (host != expectedHost && !(socket.inetAddress.isLoopbackAddress &&
                            host == "localhost:$PORT")) {
                    return sendJson(output, 403, error("Откройте веб-пульт по IP приставки"))
                }
                if (method == "POST" && headers["origin"] != "http://$host") {
                    return sendJson(output, 403, error("Запрос с другого сайта запрещён"))
                }
                val bytes = if (method == "POST") {
                    val length = headers["content-length"]?.toIntOrNull() ?: -1
                    if (length !in 1..MAX_BODY || headers["transfer-encoding"] != null) {
                        return sendJson(output, 413, error("Недопустимый размер запроса"))
                    }
                    ByteArray(length).also { body ->
                        var offset = 0
                        while (offset < body.size) {
                            val n = input.read(body, offset, body.size - offset)
                            if (n < 0) return
                            offset += n
                        }
                    }
                } else ByteArray(0)
                val body = if (method == "POST") {
                    try { JSONObject(String(bytes, Charsets.UTF_8)) }
                    catch (_: Exception) { return sendJson(output, 400, error("Неверный JSON")) }
                } else JSONObject()

                val signedIn = authenticated(headers["cookie"])
                when {
                    method == "GET" && path == "/" -> asset(output, "index.html", "text/html; charset=utf-8")
                    method == "GET" && path == "/app.js" -> asset(output, "app.js", "application/javascript; charset=utf-8")
                    method == "GET" && path == "/video.js" -> asset(output, "video.js", "application/javascript; charset=utf-8")
                    method == "GET" && path == "/style.css" -> asset(output, "style.css", "text/css; charset=utf-8")
                    method == "GET" && path == "/manifest.webmanifest" -> asset(output, "manifest.webmanifest", "application/manifest+json")
                    method == "GET" && path == "/icon.svg" -> asset(output, "icon.svg", "image/svg+xml")
                    method == "GET" && path == "/apple-touch-icon.png" -> asset(output, "apple-touch-icon.png", "image/png")
                    method == "POST" && path == "/api/pair" -> {
                        val pin = body.optString("pin")
                        if (!Regex("^[0-9]{6}$").matches(pin) || !pairing.consumeWebPin(pin)) {
                            sendJson(output, 403, error("Неправильный или просроченный PIN"))
                        } else {
                            val secret = ByteArray(32).also(random::nextBytes)
                            val token = Base64.encodeToString(secret, Base64.NO_WRAP or Base64.URL_SAFE)
                            sessions[token] = SystemClock.elapsedRealtime()
                            sendJson(output, 200, JSONObject().put("ok", true),
                                "Set-Cookie: $COOKIE=$token; Path=/; HttpOnly; SameSite=Strict; Max-Age=43200\r\n")
                        }
                    }
                    method == "GET" && path == "/api/status" -> {
                        sendJson(output, 200, JSONObject().put("ok", true)
                            .put("paired", signedIn)
                            .put("sharing", if (signedIn) ScreenCaptureService.sharing else false)
                            .put("fps", if (signedIn) ScreenCaptureService.actualEncodedFps else 0))
                    }
                    !signedIn -> sendJson(output, 401, error("Введите PIN с экрана приставки"))
                    method == "POST" && path == "/api/command" -> {
                        if (body.optString("cmd") !in ALLOWED_COMMANDS) {
                            sendJson(output, 400, error("Неизвестная команда"))
                        } else {
                            try { sendJson(output, 200, command(body)) }
                            catch (e: Exception) { sendJson(output, 500, error("Сбой команды")) }
                        }
                    }
                    method == "POST" && path == "/api/logout" -> {
                        expireCookie(headers["cookie"])
                        sendJson(output, 200, JSONObject().put("ok", true),
                            "Set-Cookie: $COOKIE=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0\r\n")
                    }
                    method == "GET" && path == "/api/video" -> {
                        if (!ScreenCaptureService.sharing) {
                            sendJson(output, 409, error("Включите трансляцию на приставке"))
                        } else if (liveStreams.incrementAndGet() > 2) {
                            liveStreams.decrementAndGet()
                            sendJson(output, 429, error("Слишком много видеоподключений"))
                        } else {
                            try { streamVideo(socket, output) }
                            finally { liveStreams.decrementAndGet() }
                        }
                    }
                    else -> sendJson(output, 404, error("Не найдено"))
                }
            }
        } catch (_: SocketException) {
            // Safari navigated away or lost Wi-Fi.
        } catch (e: Exception) {
            if (running) Log.d("PultWeb", "Browser request closed: ${e.javaClass.simpleName}")
        }
    }

    private fun authenticated(cookie: String?): Boolean {
        if (pairing.webRevocationVersion() != revokedVersion) {
            sessions.clear()
            revokedVersion = pairing.webRevocationVersion()
        }
        val token = cookie?.split(';')?.firstOrNull { it.trim().startsWith("$COOKIE=") }
            ?.substringAfter('=') ?: return false
        val timestamp = sessions[token] ?: return false
        val now = SystemClock.elapsedRealtime()
        if (now - timestamp > SESSION_IDLE_MS) {
            sessions.remove(token)
            return false
        }
        sessions[token] = now
        return true
    }

    private fun expireCookie(cookie: String?) {
        val token = cookie?.split(';')?.firstOrNull { it.trim().startsWith("$COOKIE=") }
            ?.substringAfter('=') ?: return
        sessions.remove(token)
    }

    private fun readLine(input: BufferedInputStream, limit: Int): String? {
        val out = ByteArrayOutputStream()
        while (out.size() < limit) {
            val b = input.read()
            if (b < 0) return null
            if (b == 10) return out.toString("UTF-8").trimEnd('\r')
            out.write(b)
        }
        return null
    }

    private fun asset(output: BufferedOutputStream, filename: String, type: String) {
        val bytes = context.assets.open("web/$filename").use { it.readBytes() }
        header(output, 200, "OK", type,
            "Content-Length: ${bytes.size}\r\nCache-Control: no-cache\r\n")
        output.write(bytes)
        output.flush()
    }

    private fun sendJson(output: BufferedOutputStream, code: Int, data: JSONObject, extra: String = "") {
        val bytes = data.toString().toByteArray(Charsets.UTF_8)
        header(output, code, when(code) {
            200 -> "OK"; 400 -> "Bad Request"; 401 -> "Unauthorized";
            403 -> "Forbidden"; 404 -> "Not Found"; 409 -> "Conflict";
            413 -> "Payload Too Large"; 429 -> "Too Many Requests";
            else -> "Error"
        }, "application/json; charset=utf-8", "Content-Length: ${bytes.size}\r\n$extra")
        output.write(bytes)
        output.flush()
    }

    private fun header(output: BufferedOutputStream, code: Int, reason: String,
            type: String, more: String) {
        output.write(("HTTP/1.1 $code $reason\r\n" +
            "Content-Type: $type\r\nConnection: close\r\n" +
            "X-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\n" +
            "Referrer-Policy: no-referrer\r\n" +
            "Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; " +
            "img-src 'self' data:; media-src 'self' blob:; connect-src 'self'; " +
            "object-src 'none'; frame-ancestors 'none'; base-uri 'none'\r\n" +
            more + "\r\n").toByteArray(Charsets.UTF_8))
    }

    /** Binary framed AVC over chunked HTTP. No new encoder, no duplicated capture. */
    private fun streamVideo(socket: Socket, output: BufferedOutputStream) {
        header(output, 200, "OK", "application/octet-stream",
            "Cache-Control: no-store, no-transform\r\n" +
            "X-Pult-Video-Width: ${ScreenCaptureService.videoWidth}\r\n" +
            "X-Pult-Video-Height: ${ScreenCaptureService.videoHeight}\r\n" +
            "X-Accel-Buffering: no\r\nTransfer-Encoding: chunked\r\n")
        output.flush()
        var cursor = ScreenCaptureService.latestSequence()
        var waitingKeyframe = true
        var lastSync = 0L
        val lastRevocation = pairing.webRevocationVersion()
        val start = SystemClock.elapsedRealtime()
        // Close after 15 min; Safari refreshes and repeats a cookie-authenticated GET.
        while (running && ScreenCaptureService.sharing &&
            pairing.webRevocationVersion() == lastRevocation &&
            SystemClock.elapsedRealtime() - start < 900_000L && !socket.isClosed) {
            if (ScreenCaptureService.latestSequence() - cursor > 6) {
                cursor = ScreenCaptureService.latestSequence()
                waitingKeyframe = true
            }
            val packet = ScreenCaptureService.awaitPacket(cursor, 450) ?: continue
            if (!waitingKeyframe && packet.seq != cursor + 1L) waitingKeyframe = true
            cursor = packet.seq
            if (SystemClock.elapsedRealtime() - packet.encodedAtMs > 230) {
                cursor = ScreenCaptureService.latestSequence()
                waitingKeyframe = true
                continue
            }
            if (waitingKeyframe) {
                val now = SystemClock.elapsedRealtime()
                if (now - lastSync > 450) {
                    ScreenCaptureService.requestKeyFrame()
                    lastSync = now
                }
                if ((packet.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) == 0) continue
                val config = ScreenCaptureService.codecConfig() ?: continue
                packetChunk(output, config, 0, MediaCodec.BUFFER_FLAG_CODEC_CONFIG)
                waitingKeyframe = false
            }
            packetChunk(output, packet.bytes, packet.ptsUs, packet.flags)
        }
        output.write("0\r\n\r\n".toByteArray(Charsets.US_ASCII))
        output.flush()
    }

    private fun packetChunk(output: BufferedOutputStream, bytes: ByteArray, pts: Long, flags: Int) {
        if (bytes.isEmpty() || bytes.size > 2_000_000) return
        val buffer = ByteArrayOutputStream(bytes.size + 16)
        DataOutputStream(buffer).use { data ->
            data.writeInt(bytes.size)
            data.writeLong(pts)
            data.writeInt(flags)
            data.write(bytes)
        }
        val payload = buffer.toByteArray()
        output.write("${payload.size.toString(16)}\r\n".toByteArray(Charsets.US_ASCII))
        output.write(payload)
        output.write("\r\n".toByteArray(Charsets.US_ASCII))
        output.flush()
    }

    private fun error(message: String) = JSONObject().put("ok", false).put("error", message)
}
