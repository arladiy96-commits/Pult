import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../proto/remote.pb.dart';
import 'certificate_manager.dart';

class TVRemoteClient {
  TVRemoteClient({
    required this.certManager,
    this.onDisconnected,
  });

  final CertificateManager certManager;
  final void Function(String reason)? onDisconnected;

  SecureSocket? _socket;
  StreamSubscription<List<int>>? _subscription;
  final _buffer = <int>[];

  bool _connected = false;
  int? _activeRepeatCode;

  bool get isConnected => _connected;

  Future<bool> connect(
    String ip, {
    int port = 6466,
  }) async {
    dispose();

    try {
      final context =
          await certManager.buildSecurityContext();

      _socket = await SecureSocket.connect(
        ip,
        port,
        context: context,
        timeout: const Duration(seconds: 8),
        onBadCertificate: (_) => true,
      );

      _connected = true;
      _buffer.clear();

      _subscription = _socket!.listen(
        _onData,
        onError: (error) =>
            _handleDisconnection('Ошибка соединения: $error'),
        onDone: () =>
            _handleDisconnection('Приставка закрыла соединение.'),
      );

      return true;
    } on SocketException catch (e) {
      _handleDisconnection('Ошибка сети: ${e.message}');
      return false;
    } on HandshakeException {
      _handleDisconnection('Ошибка TLS.');
      return false;
    } catch (e) {
      _handleDisconnection('Ошибка: $e');
      return false;
    }
  }

  void _onData(List<int> data) {
    _buffer.addAll(data);
    _dispatchMessages();
  }

  void _dispatchMessages() {
    while (_buffer.isNotEmpty) {
      int length = 0;
      int shift = 0;
      int prefix = 0;
      bool complete = false;

      for (var i = 0; i < _buffer.length && i < 5; i++) {
        final b = _buffer[i];
        length |= (b & 0x7F) << shift;
        prefix++;

        if ((b & 0x80) == 0) {
          complete = true;
          break;
        }

        shift += 7;
      }

      if (!complete) return;
      if (_buffer.length < prefix + length) return;

      final message = Uint8List.fromList(
        _buffer.sublist(prefix, prefix + length),
      );

      _buffer.removeRange(0, prefix + length);
      _handleMessage(message);
    }
  }

  void _handleMessage(Uint8List message) {
    final socket = _socket;
    if (!_connected || socket == null) return;

    final incoming = RemoteMessage.parse(message);

    switch (incoming.field) {
      case 1:
        socket.add(RemoteMessage.buildConfigure());
        break;
      case 2:
        socket.add(RemoteMessage.buildSetActive());
        break;
      case 8:
        socket.add(
          RemoteMessage.buildPingResponse(incoming.pingVal),
        );
        break;
      default:
        break;
    }
  }

  void sendKeyPress(int code) {
    _sendKey(code, RemoteDirection.short);
  }

  void startRepeat(int code) {
    _activeRepeatCode = code;
    _sendKey(code, RemoteDirection.startLong);
  }

  void stopRepeat() {
    final code = _activeRepeatCode;
    if (code == null) return;

    _sendKey(code, RemoteDirection.endLong);
    _activeRepeatCode = null;
  }

  void _sendKey(int code, int direction) {
    final socket = _socket;
    if (!_connected || socket == null) return;

    try {
      socket.add(
        RemoteMessage.buildKeyInject(code, direction),
      );
    } catch (e) {
      _handleDisconnection('Не удалось отправить команду: $e');
    }
  }

  void _handleDisconnection(String reason) {
    final wasConnected = _connected;

    _connected = false;
    _subscription?.cancel();
    _subscription = null;

    _socket?.destroy();
    _socket = null;

    _buffer.clear();

    if (wasConnected) {
      onDisconnected?.call(reason);
    }
  }

  void dispose() {
    _connected = false;
    _subscription?.cancel();
    _subscription = null;
    _socket?.destroy();
    _socket = null;
    _buffer.clear();
  }
}
