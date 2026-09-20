import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import '../model/remote_protocol.dart';
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
  final Queue<Uint8List> _legacyFrames = Queue<Uint8List>();
  Completer<Uint8List?>? _legacyWaiter;

  bool _connected = false;
  int? _activeRepeatCode;
  TVRemoteProtocol _protocol = TVRemoteProtocol.remoteV2;
  Future<void> _legacyTail = Future.value();

  bool get isConnected => _connected;

  Future<bool> connect(
    String ip, {
    int port = 6466,
    TVRemoteProtocol protocol = TVRemoteProtocol.remoteV2,
  }) async {
    dispose();
    _protocol = protocol;

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
      _legacyFrames.clear();

      _subscription = _socket!.listen(
        protocol == TVRemoteProtocol.legacyV1
            ? _onLegacyData
            : _onV2Data,
        onError: (error) =>
            _handleDisconnection('Ошибка соединения: $error'),
        onDone: () =>
            _handleDisconnection('Приставка закрыла соединение.'),
      );

      if (protocol == TVRemoteProtocol.legacyV1) {
        final verified = await _sendLegacyConfiguration();
        if (!verified) {
          _handleDisconnection(
            'X96 не подтвердила канал управления v1.',
          );
          return false;
        }
      }

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

  void _onV2Data(List<int> data) {
    _buffer.addAll(data);
    _dispatchV2Messages();
  }

  void _dispatchV2Messages() {
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
      _handleV2Message(message);
    }
  }

  void _handleV2Message(Uint8List message) {
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

  void _onLegacyData(List<int> data) {
    _buffer.addAll(data);

    // Android TV Remote v1 binary command frames are:
    // [1, TYPE, 0, PAYLOAD_LENGTH, ...PAYLOAD]
    while (_buffer.length >= 4) {
      if (_buffer[0] != 1 || _buffer[2] != 0) {
        _buffer.removeAt(0);
        continue;
      }

      final payloadLength = _buffer[3];
      final total = 4 + payloadLength;

      if (_buffer.length < total) return;

      final frame = Uint8List.fromList(
        _buffer.sublist(0, total),
      );
      _buffer.removeRange(0, total);
      _dispatchLegacyFrame(frame);
    }
  }

  void _dispatchLegacyFrame(Uint8List frame) {
    final waiter = _legacyWaiter;

    if (waiter != null && !waiter.isCompleted) {
      _legacyWaiter = null;
      waiter.complete(frame);
      return;
    }

    _legacyFrames.addLast(frame);
  }

  Future<Uint8List?> _readLegacyFrame({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    if (_legacyFrames.isNotEmpty) {
      return _legacyFrames.removeFirst();
    }

    final waiter = Completer<Uint8List?>();
    _legacyWaiter = waiter;

    try {
      return await waiter.future.timeout(timeout);
    } on TimeoutException {
      if (identical(_legacyWaiter, waiter)) {
        _legacyWaiter = null;
      }
      return null;
    } finally {
      if (identical(_legacyWaiter, waiter)) {
        _legacyWaiter = null;
      }
    }
  }

  Future<bool> _sendLegacyConfiguration() async {
    final socket = _socket;
    if (!_connected || socket == null) return false;

    const configuration = <int>[
      1, 0, 0, 21,
      0, 0, 0, 1,
      0, 0, 0, 1,
      32, 3,
      0, 0, 0, 0, 0, 0,
      4, 116, 101, 115, 116,
    ];

    try {
      socket.add(configuration);
      await socket.flush();

      final ack1 = await _readLegacyFrame();
      if (ack1 == null ||
          ack1.length < 3 ||
          ack1[0] != 1 ||
          ack1[1] != 7 ||
          ack1[2] != 0) {
        return false;
      }

      final ack2 = await _readLegacyFrame();
      if (ack2 == null) return false;

      final ack3 = await _readLegacyFrame();
      if (ack3 == null) return false;

      return true;
    } catch (_) {
      return false;
    }
  }

  void sendKeyPress(int code) {
    if (_protocol == TVRemoteProtocol.legacyV1) {
      _queueLegacy(() => _legacyShortKey(code));
      return;
    }

    _sendV2Key(code, RemoteDirection.short);
  }

  void startRepeat(int code) {
    _activeRepeatCode = code;

    if (_protocol == TVRemoteProtocol.legacyV1) {
      _queueLegacy(() async {
        if (!await _sendLegacyConfiguration()) return;
        _writeLegacyPress(code);
      });
      return;
    }

    _sendV2Key(code, RemoteDirection.startLong);
  }

  void stopRepeat() {
    final code = _activeRepeatCode;
    if (code == null) return;

    _activeRepeatCode = null;

    if (_protocol == TVRemoteProtocol.legacyV1) {
      _queueLegacy(() async {
        _writeLegacyRelease(code);
      });
      return;
    }

    _sendV2Key(code, RemoteDirection.endLong);
  }

  void _sendV2Key(int code, int direction) {
    final socket = _socket;
    if (!_connected || socket == null) return;

    try {
      socket.add(
        RemoteMessage.buildKeyInject(code, direction),
      );
    } catch (e) {
      _handleDisconnection(
        'Не удалось отправить команду: $e',
      );
    }
  }

  void _queueLegacy(Future<void> Function() operation) {
    final previous = _legacyTail;

    _legacyTail = () async {
      try {
        await previous;
      } catch (_) {}

      if (!_connected) return;

      try {
        await operation();
      } catch (e) {
        _handleDisconnection(
          'Не удалось отправить команду: $e',
        );
      }
    }();
  }

  Future<void> _legacyShortKey(int code) async {
    if (!await _sendLegacyConfiguration()) {
      throw StateError('нет ACK конфигурации v1');
    }

    _writeLegacyPress(code);
    await Future<void>.delayed(
      const Duration(milliseconds: 100),
    );
    _writeLegacyRelease(code);
  }

  void _writeLegacyPress(int code) {
    final socket = _socket;
    if (socket == null) return;

    socket.add([
      1, 2, 0, 16,
      0, 0, 0, 0,
      0, 0, 0, 0,
      0, 0, 0, 0,
      0, 0, 0, code & 0xFF,
    ]);
  }

  void _writeLegacyRelease(int code) {
    final socket = _socket;
    if (socket == null) return;

    socket.add([
      1, 2, 0, 16,
      0, 0, 0, 0,
      0, 0, 0, 1,
      0, 0, 0, 1,
      0, 0, 0, code & 0xFF,
    ]);
  }

  void _handleDisconnection(String reason) {
    final wasConnected = _connected;

    _connected = false;
    _subscription?.cancel();
    _subscription = null;

    _socket?.destroy();
    _socket = null;

    _buffer.clear();
    _legacyFrames.clear();

    final waiter = _legacyWaiter;
    _legacyWaiter = null;
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete(null);
    }

    if (wasConnected) {
      onDisconnected?.call(reason);
    }
  }

  void dispose() {
    _connected = false;
    _activeRepeatCode = null;

    _subscription?.cancel();
    _subscription = null;

    _socket?.destroy();
    _socket = null;

    _buffer.clear();
    _legacyFrames.clear();

    final waiter = _legacyWaiter;
    _legacyWaiter = null;
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete(null);
    }

    _legacyTail = Future.value();
  }
}
