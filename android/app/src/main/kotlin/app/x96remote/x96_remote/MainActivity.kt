package app.x96remote.x96_remote

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var player: AvcStreamPlayer? = null
    private var videoChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pult/h264")
        videoChannel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val host = call.argument<String>("host")
                    val sha256 = call.argument<String>("fingerprint")
                    val token = call.argument<String>("token")
                    if (host.isNullOrBlank() || sha256.isNullOrBlank() || token.isNullOrBlank()) {
                        result.error("ARGS", "Нет данных защищённого соединения", null)
                        return@setMethodCallHandler
                    }
                    player?.stop()
                    player = AvcStreamPlayer(flutterEngine.renderer, host, sha256, token) { message, w, h ->
                        videoChannel?.invokeMethod("status", mapOf("message" to message,
                            "width" to w, "height" to h))
                    }.also { it.start() }
                    result.success(player!!.textureId)
                }
                "stop" -> {
                    player?.stop()
                    player = null
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        player?.stop()
        player = null
        videoChannel?.setMethodCallHandler(null)
        videoChannel = null
        super.onDestroy()
    }
}
