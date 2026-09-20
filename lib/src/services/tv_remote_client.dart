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

  // Used only for the old binary command protocol fallback.
  final Queue<Uint8List> _legacyFrames = Queue<Uint8List>();
  Completer<bool>? _legacyConfigAck;

  // Used while determining what protocol port 6466 actually speaks.
  Completer<bool>? _v2Probe;

  bool _connected = false;
  bool _probing = false;
  int? _activeRepeatCode;

  // IMPORTANT:
  // Pairing protocol and command protocol are NOT assumed to be the same.
  // Some older X96 / Android TV builds pair through the old pairing service
  // but still speak protobuf Remote v2 on port 6466.
  TVRemoteProtocol _commandProtocol = TVRemoteProtocol.remoteV2;

  Future<void> _legacyTail = Future.value();

  bool get isConnected => _connected;

  Future<bool> connect(
    String ip, {
    int port = 6466,
    TVRemoteProtocol protocol = TVRemoteProtocol.remoteV2,
  }) async {
    // [protocol] is the PAIRING protocol stored by the app. It is only a hint.
    // We independently detect the command protocol on port 6466.
    _closeSocket(notify: false);

    // First try the protocol used by current Android TV Remote Service:
    // TLS + protobuf RemoteMessage on 6466.
    final v2 = await _tryV2CommandChannel(ip, port);
    if (v2) {
      _commandProtocol = TVRemoteProtocol.remoteV2;
      _connected = true;
      return true;
    }

    // Only if port 6466 did not speak v2, try the older binary command format.
    final legacy = await _tryLegacyCommandChannel(ip, port);
    if (legacy) {
      _commandProtocol = TVRemoteProtocol.legacyV1;
      _connected = true;
      return true;
    }

    _closeSocket(notify: false);
    return false;
  }

  Future<bool> _tryV2CommandChannel(
    String ip,
    int port,
  ) async {
    try {
      final context =
          await certManager.buildSecurityContext();

      final socket = await SecureSocket.connect(
        ip,
        port,
        context: context,
        timeout: const Duration(seconds: 8),
        onBadCertificate: (_) => true,
      );

      _socket = socket;
      _buffer.clear();

      final probe = Completer<bool>();
      _v2Probe = probe;
      _probing = true;

      _subscription = socket.listen(
        _onV2Data,
        onError: (_) {
          if (!probe.isCompleted) {
            probe.complete(false);
          }
        },
        onDone: () {
          if (!probe.isCompleted) {
            probe.complete(false);
          } else if (!_probing && _connected) {
            _handleDisconnection(
              'Приставка закрыла соединение.',
            );
          }
        },
      );

      // A genuine Remote v2 service normally sends RemoteConfigure /
      // RemoteSetActive / RemoteStart immediately after TLS connects.
      final detected = await probe.future
          .timeout(
            const Duration(seconds: 4),
            onTimeout: () => false,
          );

      _v2Probe = null;
      _probing = false;

      if (!detected) {
        _closeSocket(notify: false);
        return false;
      }

      return true;
    } on SocketException {
      _closeSocket(notify: false);
      return false;
    } on HandshakeException {
      _closeSocket(notify: false);
      return false;
    } catch (_) {
      _closeSocket(notify: false);
      return false;
    }
  }

  Future<bool> _tryLegacyCommandChannel(
    String ip,
    int port,
  ) async {
    try {
      final context =
          await certManager.buildSecurityContext();

      final socket = await SecureSocket.connect(
        ip,
        port,
        context: context,
        timeout: const Duration(seconds: 8),
        onBadCertificate: (_) => true,
      );

      _socket = socket;
      _buffer.clear();
      _legacyFrames.clear();

      _subscription = socket.listen(
        _onLegacyData,
        onError: (_) {},
        onDone: () {
          if (_connected) {
            _handleDisconnection(
              'Приставка закрыла соединение.',
            );
          }
        },
      );

      // Verify the old command channel once. The old implementation's ACK
      // is not protobuf and is not safely frameable by byte 3, so we look
      // for its documented ACK signature in the incoming byte stream.
      final ok = await _sendLegacyConfiguration();
      if (!ok) {
        _closeSocket(notify: false);
        return false;
      }

      return true;
    } catch (_) {
      _closeSocket(notify: false);
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Remote v2
  // ---------------------------------------------------------------------------

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

      // Reject an obviously impossible v2 frame while probing.
      if (length < 0 || length > 1024 * 1024) {
        final probe = _v2Probe;
        if (probe != null && !probe.isCompleted) {
          probe.complete(false);
        }
        return;
      }

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
    if (socket == null) return;

    final incoming = RemoteMessage.parse(message);
    final field = incoming.field;

    // These are valid RemoteMessage fields that prove port 6466 is v2.
    const knownRemoteFields = <int>{
      1,  // remote_configure
      2,  // remote_set_active
      3,  // remote_error
      8,  // remote_ping_request
      9,  // remote_ping_response
      10, // remote_key_inject
      20, 21, 22,
      30, 31, 32,
      40, // remote_start
      50, 51,
      60, 61,
      90,
    };

    if (knownRemoteFields.contains(field)) {
      final probe = _v2Probe;
      if (probe != null && !probe.isCompleted) {
        probe.complete(true);
      }
    }

    // Handshake required by Android TV Remote v2.
    switch (field) {
      case 1:
        socket.add(RemoteMessage.buildConfigure());
        break;

      case 2:
        socket.add(RemoteMessage.buildSetActive());
        break;

      case 8:
        socket.add(
          RemoteMessage.buildPingResponse(
            incoming.pingVal,
          ),
        );
        break;

      default:
        break;
    }
  }

  // ---------------------------------------------------------------------------
  // Old command protocol fallback
  // ---------------------------------------------------------------------------

  void _onLegacyData(List<int> data) {
    _buffer.addAll(data);

    // The old implementation checks only the first three ACK bytes:
    // [1, 7, 0]. TCP/TLS chunking means those bytes may be inside a larger
    // chunk, so search the stream instead of treating byte 3 as frame length.
    if (_containsSequence(_buffer, const [1, 7, 0])) {
      final ack = _legacyConfigAck;
      if (ack != null && !ack.isCompleted) {
        ack.complete(true);
      }
    }

    // Keep the buffer bounded. We only need recent bytes for ACK detection.
    if (_buffer.length > 4096) {
      _buffer.removeRange(0, _buffer.length - 1024);
    }
  }

  bool _containsSequence(
    List<int> source,
    List<int> needle,
  ) {
    if (needle.isEmpty || source.length < needle.length) {
      return false;
    }

    for (var i = 0;
        i <= source.length - needle.length;
        i++) {
      var match = true;

      for (var j = 0; j < needle.length; j++) {
        if (source[i + j] != needle[j]) {
          match = false;
          break;
        }
      }

      if (match) return true;
    }

    return false;
  }

  Future<bool> _sendLegacyConfiguration() async {
    final socket = _socket;
    if (socket == null) return false;

    const configuration = <int>[
      1, 0, 0, 21,
      0, 0, 0, 1,
      0, 0, 0, 1,
      32, 3,
      0, 0, 0, 0, 0, 0,
      4, 116, 101, 115, 116,
    ];

    try {
      _buffer.clear();

      final ack = Completer<bool>();
      _legacyConfigAck = ack;

      socket.add(configuration);
      await socket.flush();

      final ok = await ack.future.timeout(
        const Duration(seconds: 3),
        onTimeout: () => false,
      );

      if (identical(_legacyConfigAck, ack)) {
        _legacyConfigAck = null;
      }

      return ok;
    } catch (_) {
      _legacyConfigAck = null;
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Public key commands
  // ---------------------------------------------------------------------------

  void sendKeyPress(int code) {
    if (_commandProtocol == TVRemoteProtocol.legacyV1) {
      _queueLegacy(() => _legacyShortKey(code));
      return;
    }

    _sendV2Key(
      code,
      RemoteDirection.short,
    );
  }

  void startRepeat(int code) {
    _activeRepeatCode = code;

    if (_commandProtocol == TVRemoteProtocol.legacyV1) {
      _queueLegacy(() async {
        if (!await _sendLegacyConfiguration()) {
          throw StateError(
            'нет ACK конфигурации старого протокола',
          );
        }
        _writeLegacyPress(code);
      });
      return;
    }

    _sendV2Key(
      code,
      RemoteDirection.startLong,
    );
  }

  void stopRepeat() {
    final code = _activeRepeatCode;
    if (code == null) return;

    _activeRepeatCode = null;

    if (_commandProtocol == TVRemoteProtocol.legacyV1) {
      _queueLegacy(() async {
        _writeLegacyRelease(code);
      });
      return;
    }

    _sendV2Key(
      code,
      RemoteDirection.endLong,
    );
  }

  void _sendV2Key(
    int code,
    int direction,
  ) {
    final socket = _socket;

    if (!_connected || socket == null) return;

    try {
      socket.add(
        RemoteMessage.buildKeyInject(
          code,
          direction,
        ),
      );
    } catch (e) {
      _handleDisconnection(
        'Не удалось отправить команду: $e',
      );
    }
  }

  void _queueLegacy(
    Future<void> Function() operation,
  ) {
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
      throw StateError(
        'нет ACK конфигурации старого протокола',
      );
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

  // ---------------------------------------------------------------------------
  // Cleanup
  // ---------------------------------------------------------------------------

  void _handleDisconnection(String reason) {
    final wasConnected = _connected;

    _closeSocket(notify: false);

    if (wasConnected) {
      onDisconnected?.call(reason);
    }
  }

  void _closeSocket({
    required bool notify,
  }) {
    _connected = false;
    _probing = false;
    _activeRepeatCode = null;

    _subscription?.cancel();
    _subscription = null;

    _socket?.destroy();
    _socket = null;

    _buffer.clear();
    _legacyFrames.clear();

    final legacyAck = _legacyConfigAck;
    _legacyConfigAck = null;
    if (legacyAck != null && !legacyAck.isCompleted) {
      legacyAck.complete(false);
    }

    final probe = _v2Probe;
    _v2Probe = null;
    if (probe != null && !probe.isCompleted) {
      probe.complete(false);
    }

    _legacyTail = Future.value();
  }

  void dispose() {
    _closeSocket(notify: false);
  }
}
