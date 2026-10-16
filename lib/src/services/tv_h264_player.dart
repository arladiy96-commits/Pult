import 'package:flutter/services.dart';

/// Android MediaCodec decoder that renders H.264 directly into a Flutter Texture.
/// Uses a second certificate-pinned TLS connection, independent of touch events.
class TvH264Player {
  static const MethodChannel _channel = MethodChannel('pult/h264');
  TvH264Player(this.onStatus) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'status') {
        final args = Map<String, dynamic>.from(call.arguments as Map);
        onStatus('${args['message'] ?? ''}',
          (args['width'] as num?)?.toInt() ?? 1280,
          (args['height'] as num?)?.toInt() ?? 720);
      }
    });
  }

  final void Function(String message, int width, int height) onStatus;

  Future<int> start({required String host, required String fingerprint,
      required String token}) async {
    final id = await _channel.invokeMethod<int>('start', {
      'host': host, 'fingerprint': fingerprint, 'token': token,
    });
    if (id == null) throw StateError('Android не создал видеоповерхность');
    return id;
  }

  Future<void> stop() async => _channel.invokeMethod<void>('stop');

  void dispose() {
    _channel.setMethodCallHandler(null);
  }
}
