import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../model/remote_protocol.dart';
import '../proto/remote.pb.dart';
import 'certificate_manager.dart';

enum _PairingWire {
  legacyJson,
  protobufV2,
}

class TVSecurityManager {
  TVSecurityManager({
    required this.certManager,
  });

  final CertificateManager certManager;
  final _storage = const FlutterSecureStorage();

  SecureSocket? _pairingSocket;
  Uint8List? _serverCertDer;
  StreamSubscription<List<int>>? _socketSubscription;

  final _buffer = <int>[];
  final Queue<Uint8List> _pendingMessages = Queue<Uint8List>();
  Completer<Uint8List?>? _messageWaiter;

  _PairingWire _wire = _PairingWire.protobufV2;
  TVRemoteProtocol? _activeProtocol;

  TVRemoteProtocol? get currentProtocol => _activeProtocol;
  int get currentPinLength => _activeProtocol?.pinLength ?? 6;

  String _pairedKey(String ip) => 'x96_paired_$ip';
  String _protocolKey(String ip) => 'x96_protocol_$ip';

  Future<bool> hasPairedStorage(String ip) =>
      _storage.containsKey(key: _pairedKey(ip));

  Future<TVRemoteProtocol?> protocolFor(String ip) async {
    final raw = await _storage.read(key: _protocolKey(ip));
    return TVRemoteProtocolInfo.fromStorage(raw);
  }

  Future<void> _markPaired(
    String ip,
    TVRemoteProtocol protocol,
  ) async {
    await _storage.write(key: _pairedKey(ip), value: 'paired');
    await _storage.write(
      key: _protocolKey(ip),
      value: protocol.storageValue,
    );
  }

  Future<void> clearPairing(String ip) async {
    await _storage.delete(key: _pairedKey(ip));
    await _storage.delete(key: _protocolKey(ip));
  }

  Future<String?> initiatePairing(
    String ip, {
    int port = 6467,
  }) async {
    _activeProtocol = null;
    _cleanupSocket();

    // X96 / Android 9 devices frequently expose the older Android TV
    // Remote v1 protocol on the same 6467 pairing port. Try that first.
    final legacyError = await _beginLegacyV1(ip, port: port);
    if (legacyError == null) {
      _activeProtocol = TVRemoteProtocol.legacyV1;
      return null;
    }

    _cleanupSocket();

    // Newer Android TV Remote Service uses protobuf v2.
    final v2Error = await _beginRemoteV2(ip, port: port);
    if (v2Error == null) {
      _activeProtocol = TVRemoteProtocol.remoteV2;
      return null;
    }

    _cleanupSocket();

    return 'Pairing не подтвердился. '
        'v1: $legacyError • v2: $v2Error';
  }

  Future<String?> _beginLegacyV1(
    String ip, {
    required int port,
  }) async {
    try {
      await _openPairingSocket(
        ip,
        port: port,
        wire: _PairingWire.legacyJson,
      );

      await _sendLegacyJson({
        'protocol_version': 1,
        'payload': {
          'service_name': 'androidtvremote',
          'client_name': 'X96 Remote',
        },
        'type': 10,
        'status': 200,
      });

      final ack1 = await _readLegacyResponse(
        timeout: const Duration(seconds: 3),
      );
      if (!_legacyResponseIs(ack1, 11)) {
        return _legacyError('нет PairingRequestAck', ack1);
      }

      await _sendLegacyJson({
        'protocol_version': 1,
        'payload': {
          'output_encodings': [
            {'symbol_length': 4, 'type': 3},
          ],
          'input_encodings': [
            {'symbol_length': 4, 'type': 3},
          ],
          'preferred_role': 1,
        },
        'type': 20,
        'status': 200,
      });

      final ack2 = await _readLegacyResponse(
        timeout: const Duration(seconds: 3),
      );
      if (!_legacyResponseIs(ack2, 20)) {
        return _legacyError('нет Options ответа', ack2);
      }

      await _sendLegacyJson({
        'protocol_version': 1,
        'payload': {
          'encoding': {
            'symbol_length': 4,
            'type': 3,
          },
          'client_role': 1,
        },
        'type': 30,
        'status': 200,
      });

      final ack3 = await _readLegacyResponse(
        timeout: const Duration(seconds: 3),
      );
      if (!_legacyResponseIs(ack3, 31)) {
        return _legacyError('нет ConfigurationAck', ack3);
      }

      return null;
    } on TimeoutException {
      return 'таймаут';
    } on SocketException catch (e) {
      return 'сеть: ${e.message}';
    } on HandshakeException catch (e) {
      return 'TLS: $e';
    } catch (e) {
      return '$e';
    }
  }

  Future<String?> _beginRemoteV2(
    String ip, {
    required int port,
  }) async {
    try {
      await _openPairingSocket(
        ip,
        port: port,
        wire: _PairingWire.protobufV2,
      );

      _pairingSocket!.add(
        PairingMessage.buildRequest(
          serviceName: 'atvremote',
          clientName: 'X96 Remote',
        ),
      );
      await _pairingSocket!.flush();

      final ack1 = await _readNextMessage(
        timeout: const Duration(seconds: 4),
      );
      final response1 = ack1 == null
          ? -1
          : PairingMessage.parseResponseField(ack1);

      if (response1 != 11) {
        return 'нет PairingRequestAck (поле $response1)';
      }

      _pairingSocket!.add(PairingMessage.buildOptions());
      await _pairingSocket!.flush();

      final ack2 = await _readNextMessage(
        timeout: const Duration(seconds: 4),
      );
      final response2 = ack2 == null
          ? -1
          : PairingMessage.parseResponseField(ack2);

      // Most implementations echo Options in field 20.
      // Some implementations use an OptionsAck-like field 21.
      if (response2 != 20 && response2 != 21) {
        return 'нет Options ответа (поле $response2)';
      }

      _pairingSocket!.add(PairingMessage.buildConfiguration());
      await _pairingSocket!.flush();

      final ack3 = await _readNextMessage(
        timeout: const Duration(seconds: 4),
      );
      final response3 = ack3 == null
          ? -1
          : PairingMessage.parseResponseField(ack3);

      if (response3 != 31) {
        return 'нет ConfigurationAck (поле $response3)';
      }

      return null;
    } on TimeoutException {
      return 'таймаут';
    } on SocketException catch (e) {
      return 'сеть: ${e.message}';
    } on HandshakeException catch (e) {
      return 'TLS: $e';
    } catch (e) {
      return '$e';
    }
  }

  Future<void> _openPairingSocket(
    String ip, {
    required int port,
    required _PairingWire wire,
  }) async {
    final context = await certManager.buildSecurityContext();

    X509Certificate? serverCert;

    final socket = await SecureSocket.connect(
      ip,
      port,
      context: context,
      timeout: const Duration(seconds: 8),
      onBadCertificate: (certificate) {
        serverCert = certificate;
        return true;
      },
    );

    _pairingSocket = socket;
    _serverCertDer =
        serverCert?.der ?? socket.peerCertificate?.der;

    if (_serverCertDer == null) {
      socket.destroy();
      _pairingSocket = null;
      throw StateError('не получен сертификат X96');
    }

    _attachSocketReader(socket, wire);
  }

  Future<bool> sendPinChallenge(
    String ip,
    String pin,
  ) async {
    final protocol = _activeProtocol;
    if (protocol == null ||
        _pairingSocket == null ||
        _serverCertDer == null) {
      return false;
    }

    return switch (protocol) {
      TVRemoteProtocol.legacyV1 =>
        _sendLegacyPin(ip, pin),
      TVRemoteProtocol.remoteV2 =>
        _sendV2Pin(ip, pin),
    };
  }

  Future<bool> _sendLegacyPin(
    String ip,
    String pin,
  ) async {
    try {
      final normalized = _normalizeHexPin(pin);

      if (!RegExp(r'^[0-9A-F]{4}$').hasMatch(normalized)) {
        return false;
      }

      // Android TV Remote v1 uses a 4-symbol HEX code.
      // The pairing hash contains ONLY the last two HEX symbols
      // (one nonce byte). Do not reject the code locally: older
      // implementations do not guarantee that the first byte is a
      // locally-verifiable checksum. The TV itself is authoritative
      // and accepts/rejects the secret with type 41 / BAD_SECRET.
      final secret = await _buildPairingSecret(
        normalized,
        nonceStart: 2,
      );
      if (secret == null) return false;

      await _sendLegacyJson({
        'protocol_version': 1,
        'payload': {
          'secret': base64.encode(secret),
        },
        'type': 40,
        'status': 200,
      });

      final ack = await _readLegacyResponse(
        timeout: const Duration(seconds: 10),
      );

      if (!_legacyResponseIs(ack, 41)) {
        return false;
      }

      await _markPaired(ip, TVRemoteProtocol.legacyV1);
      _cleanupSocket();
      return true;
    } catch (_) {
      _cleanupSocket();
      return false;
    }
  }

  Future<bool> _sendV2Pin(
    String ip,
    String pin,
  ) async {
    try {
      final normalized = _normalizeHexPin(pin);

      // Different Android TV Remote Service builds expose the v2
      // challenge as either the full 6 HEX symbols or allow entering
      // just the final 4. In both cases the SHA-256 input uses the
      // final four HEX symbols (two nonce bytes).
      final valid = RegExp(r'^[0-9A-F]{4}$').hasMatch(normalized) ||
          RegExp(r'^[0-9A-F]{6}$').hasMatch(normalized);

      if (!valid) {
        return false;
      }

      final nonceCode = normalized.length == 6
          ? normalized.substring(2)
          : normalized;

      final secret = await _buildPairingSecret(
        nonceCode,
        nonceStart: 0,
      );
      if (secret == null) return false;

      // Let the TV validate the pairing secret. This is more compatible
      // than rejecting locally based on the first displayed byte.
      _pairingSocket!.add(
        PairingMessage.buildSecret(secret),
      );
      await _pairingSocket!.flush();

      final ack = await _readNextMessage(
        timeout: const Duration(seconds: 10),
      );

      final response = ack == null
          ? -1
          : PairingMessage.parseResponseField(ack);

      if (response != 41) {
        return false;
      }

      await _markPaired(ip, TVRemoteProtocol.remoteV2);
      _cleanupSocket();
      return true;
    } catch (_) {
      _cleanupSocket();
      return false;
    }
  }

  Future<List<int>?> _buildPairingSecret(
    String normalizedPin, {
    required int nonceStart,
  }) async {
    final clientKey = await _rsaKeyFromClientCert();
    final serverKey = _rsaKeyFromCertDer(_serverCertDer!);

    if (clientKey == null || serverKey == null) {
      return null;
    }

    final clientModulus = _bigIntToBytes(
      clientKey.modulus!,
      byteLength: 256,
    );
    final clientExponent =
        _bigIntToBytes(clientKey.exponent!);

    final serverModulus = _bigIntToBytes(
      serverKey.modulus!,
      byteLength: 256,
    );
    final serverExponent =
        _bigIntToBytes(serverKey.exponent!);

    final nonceHex = normalizedPin.substring(nonceStart);
    final nonce = <int>[];

    for (var i = 0; i < nonceHex.length; i += 2) {
      nonce.add(
        int.parse(
          nonceHex.substring(i, i + 2),
          radix: 16,
        ),
      );
    }

    return sha256.convert([
      ...clientModulus,
      ...clientExponent,
      ...serverModulus,
      ...serverExponent,
      ...nonce,
    ]).bytes;
  }

  String _normalizeHexPin(String pin) => pin
      .trim()
      .replaceFirst(RegExp(r'^(?:0x|0X)'), '')
      .toUpperCase();

  Future<RSAPublicKey?> _rsaKeyFromClientCert() async {
    final pem = await certManager.getClientCertPem();
    return _rsaKeyFromCertPem(pem);
  }

  static RSAPublicKey? _rsaKeyFromCertPem(String pem) {
    try {
      final cert = X509Utils.x509CertificateFromPem(pem);
      final spkiHex =
          cert.tbsCertificate?.subjectPublicKeyInfo.bytes;
      return _rsaKeyFromSpkiHex(spkiHex);
    } catch (_) {
      return null;
    }
  }

  static RSAPublicKey? _rsaKeyFromCertDer(Uint8List der) {
    try {
      final b64 = base64.encode(der);
      final lines = <String>[];

      for (var i = 0; i < b64.length; i += 64) {
        lines.add(
          b64.substring(
            i,
            i + 64 > b64.length ? b64.length : i + 64,
          ),
        );
      }

      final pem =
          '-----BEGIN CERTIFICATE-----\n'
          '${lines.join('\n')}\n'
          '-----END CERTIFICATE-----';

      return _rsaKeyFromCertPem(pem);
    } catch (_) {
      return null;
    }
  }

  static RSAPublicKey? _rsaKeyFromSpkiHex(String? hex) {
    if (hex == null) return null;

    try {
      final bytes = Uint8List.fromList(
        List.generate(
          hex.length ~/ 2,
          (i) => int.parse(
            hex.substring(i * 2, i * 2 + 2),
            radix: 16,
          ),
        ),
      );

      return CryptoUtils.rsaPublicKeyFromDERBytes(bytes);
    } catch (_) {
      return null;
    }
  }

  static List<int> _bigIntToBytes(
    BigInt value, {
    int? byteLength,
  }) {
    var hex = value.toRadixString(16);

    if (hex.length.isOdd) {
      hex = '0$hex';
    }

    if (byteLength != null) {
      hex = hex.padLeft(byteLength * 2, '0');
    }

    return List.generate(
      hex.length ~/ 2,
      (i) => int.parse(
        hex.substring(i * 2, i * 2 + 2),
        radix: 16,
      ),
    );
  }

  Future<void> _sendLegacyJson(
    Map<String, Object?> message,
  ) async {
    final socket = _pairingSocket;
    if (socket == null) {
      throw StateError('pairing socket closed');
    }

    final body = utf8.encode(jsonEncode(message));
    final size = body.length;

    final frame = <int>[
      (size >> 24) & 0xFF,
      (size >> 16) & 0xFF,
      (size >> 8) & 0xFF,
      size & 0xFF,
      ...body,
    ];

    socket.add(frame);
    await socket.flush();
  }

  Future<Map<String, dynamic>?> _readLegacyResponse({
    required Duration timeout,
  }) async {
    final raw = await _readNextMessage(timeout: timeout);
    if (raw == null) return null;

    try {
      final decoded = jsonDecode(utf8.decode(raw));
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return decoded.map(
          (key, value) => MapEntry('$key', value),
        );
      }
    } catch (_) {
      return null;
    }

    return null;
  }

  bool _legacyResponseIs(
    Map<String, dynamic>? message,
    int expectedType,
  ) {
    if (message == null) return false;

    final type = message['type'];
    final status = message['status'];

    return type == expectedType && status == 200;
  }

  String _legacyError(
    String fallback,
    Map<String, dynamic>? message,
  ) {
    if (message == null) return fallback;

    return '$fallback '
        '(type=${message['type']}, status=${message['status']})';
  }

  void cancelPairing() {
    _activeProtocol = null;
    _cleanupSocket();
  }

  void dispose() {
    _activeProtocol = null;
    _cleanupSocket();
  }

  void _attachSocketReader(
    SecureSocket socket,
    _PairingWire wire,
  ) {
    _wire = wire;
    _buffer.clear();
    _pendingMessages.clear();

    final oldWaiter = _messageWaiter;
    _messageWaiter = null;
    if (oldWaiter != null && !oldWaiter.isCompleted) {
      oldWaiter.complete(null);
    }

    _socketSubscription?.cancel();

    _socketSubscription = socket.listen(
      (data) {
        _buffer.addAll(data);

        switch (_wire) {
          case _PairingWire.legacyJson:
            _dispatchLegacyJsonFrames();
            break;
          case _PairingWire.protobufV2:
            _dispatchVarintFrames();
            break;
        }
      },
      onError: (_) {},
      onDone: () {
        final waiter = _messageWaiter;
        _messageWaiter = null;
        if (waiter != null && !waiter.isCompleted) {
          waiter.complete(null);
        }
      },
    );
  }

  void _dispatchLegacyJsonFrames() {
    while (_buffer.isNotEmpty) {
      // Normal v1 framing: 4-byte big-endian body length + JSON.
      if (_buffer.length >= 4) {
        final length =
            (_buffer[0] << 24) |
            (_buffer[1] << 16) |
            (_buffer[2] << 8) |
            _buffer[3];

        if (length > 0 && length <= 1024 * 1024) {
          if (_buffer.length < 4 + length) return;

          final message = Uint8List.fromList(
            _buffer.sublist(4, 4 + length),
          );
          _buffer.removeRange(0, 4 + length);
          _dispatchMessage(message);
          continue;
        }
      }

      // Compatibility fallback for implementations that expose the JSON
      // body separately from the 4-byte size prefix at TLS record boundaries.
      final jsonStart = _buffer.indexOf(123); // "{"
      if (jsonStart > 0) {
        _buffer.removeRange(0, jsonStart);
      }

      if (_buffer.isEmpty || _buffer.first != 123) {
        return;
      }

      try {
        jsonDecode(utf8.decode(_buffer));
        final message = Uint8List.fromList(_buffer);
        _buffer.clear();
        _dispatchMessage(message);
      } catch (_) {
        return;
      }
    }
  }

  void _dispatchVarintFrames() {
    while (_buffer.isNotEmpty) {
      int len = 0;
      int shift = 0;
      int prefix = 0;
      bool complete = false;

      for (var i = 0; i < _buffer.length && i < 5; i++) {
        final b = _buffer[i];
        len |= (b & 0x7F) << shift;
        prefix++;

        if ((b & 0x80) == 0) {
          complete = true;
          break;
        }
        shift += 7;
      }

      if (!complete) return;
      if (_buffer.length < prefix + len) return;

      final message = Uint8List.fromList(
        _buffer.sublist(prefix, prefix + len),
      );

      _buffer.removeRange(0, prefix + len);
      _dispatchMessage(message);
    }
  }

  void _dispatchMessage(Uint8List message) {
    final waiter = _messageWaiter;

    if (waiter != null && !waiter.isCompleted) {
      _messageWaiter = null;
      waiter.complete(message);
      return;
    }

    _pendingMessages.addLast(message);
  }

  Future<Uint8List?> _readNextMessage({
    required Duration timeout,
  }) async {
    if (_pendingMessages.isNotEmpty) {
      return _pendingMessages.removeFirst();
    }

    final waiter = Completer<Uint8List?>();
    _messageWaiter = waiter;

    try {
      return await waiter.future.timeout(timeout);
    } on TimeoutException {
      if (identical(_messageWaiter, waiter)) {
        _messageWaiter = null;
      }
      return null;
    } finally {
      if (identical(_messageWaiter, waiter)) {
        _messageWaiter = null;
      }
    }
  }

  void _cleanupSocket() {
    _socketSubscription?.cancel();
    _socketSubscription = null;

    _pairingSocket?.destroy();
    _pairingSocket = null;

    _serverCertDer = null;
    _buffer.clear();
    _pendingMessages.clear();

    final waiter = _messageWaiter;
    _messageWaiter = null;
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete(null);
    }
  }
}
