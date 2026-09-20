import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../proto/remote.pb.dart';
import 'certificate_manager.dart';

class TVSecurityManager {
  TVSecurityManager({
    required this.certManager,
  });

  final CertificateManager certManager;
  final _storage = const FlutterSecureStorage();

  SecureSocket? _pairingSocket;
  Uint8List? _serverCertDer;
  final _buffer = <int>[];

  // Pairing replies can arrive extremely quickly on a local network.
  // A broadcast StreamController drops events when nobody is listening.
  // Keep complete protobuf frames in a queue instead so no ACK is lost.
  final Queue<Uint8List> _pendingMessages = Queue<Uint8List>();
  Completer<Uint8List?>? _messageWaiter;

  StreamSubscription<List<int>>? _socketSubscription;

  String _key(String ip) => 'x96_paired_$ip';

  Future<bool> hasPairedStorage(String ip) =>
      _storage.containsKey(key: _key(ip));

  Future<void> markPaired(String ip) =>
      _storage.write(key: _key(ip), value: 'paired');

  Future<void> clearPairing(String ip) =>
      _storage.delete(key: _key(ip));

  Future<String?> initiatePairing(
    String ip, {
    int port = 6467,
  }) async {
    try {
      final context = await certManager.buildSecurityContext();

      X509Certificate? serverCert;

      _pairingSocket = await SecureSocket.connect(
        ip,
        port,
        context: context,
        timeout: const Duration(seconds: 8),
        onBadCertificate: (certificate) {
          serverCert = certificate;
          return true;
        },
      );

      _serverCertDer =
          serverCert?.der ?? _pairingSocket?.peerCertificate?.der;

      if (_serverCertDer == null) {
        _cleanupSocket();
        return 'Не удалось получить сертификат приставки.';
      }

      _attachSocketReader(_pairingSocket!);

      _pairingSocket!.add(
        PairingMessage.buildRequest(
          serviceName: 'atvremote',
          clientName: 'X96 Remote',
        ),
      );
      await _pairingSocket!.flush();

      final ack1 = await _readNextMessage(
        timeout: const Duration(seconds: 10),
      );
      if (ack1 == null ||
          PairingMessage.parseResponseField(ack1) < 0) {
        _cleanupSocket();
        return 'Приставка не подтвердила начало pairing.';
      }

      _pairingSocket!.add(PairingMessage.buildOptions());
      await _pairingSocket!.flush();

      final ack2 = await _readNextMessage(
        timeout: const Duration(seconds: 10),
      );
      if (ack2 == null ||
          PairingMessage.parseResponseField(ack2) < 0) {
        _cleanupSocket();
        return 'Ошибка согласования параметров pairing.';
      }

      _pairingSocket!.add(PairingMessage.buildConfiguration());
      await _pairingSocket!.flush();

      final ack3 = await _readNextMessage(
        timeout: const Duration(seconds: 10),
      );
      if (ack3 == null) {
        _cleanupSocket();
        return 'Приставка не показала код.';
      }

      final response = PairingMessage.parseResponseField(ack3);
      if (response != 31 && response < 0) {
        _cleanupSocket();
        return 'Приставка отклонила pairing.';
      }

      return null;
    } on TimeoutException {
      _cleanupSocket();
      return 'Приставка не ответила вовремя.';
    } on SocketException catch (e) {
      _cleanupSocket();
      return 'Ошибка сети: ${e.message}';
    } on HandshakeException {
      _cleanupSocket();
      return 'Ошибка защищённого соединения.';
    } catch (e) {
      _cleanupSocket();
      return 'Ошибка pairing: $e';
    }
  }

  Future<bool> sendPinChallenge(
    String ip,
    String pin,
  ) async {
    if (_pairingSocket == null || _serverCertDer == null) {
      return false;
    }

    try {
      final normalized = pin
          .trim()
          .replaceFirst(RegExp(r'^(?:0x|0X)'), '')
          .toUpperCase();

      if (!RegExp(r'^[0-9A-F]{6}$').hasMatch(normalized)) {
        return false;
      }

      final clientKey = await _rsaKeyFromClientCert();
      final serverKey = _rsaKeyFromCertDer(_serverCertDer!);

      if (clientKey == null || serverKey == null) {
        _cleanupSocket();
        return false;
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

      final checkByte =
          int.parse(normalized.substring(0, 2), radix: 16);

      final nonce = [
        int.parse(normalized.substring(2, 4), radix: 16),
        int.parse(normalized.substring(4, 6), radix: 16),
      ];

      final secret = sha256.convert([
        ...clientModulus,
        ...clientExponent,
        ...serverModulus,
        ...serverExponent,
        ...nonce,
      ]).bytes;

      if (secret.first != checkByte) {
        return false;
      }

      _pairingSocket!.add(
        PairingMessage.buildSecret(secret),
      );
      await _pairingSocket!.flush();

      final ack = await _readNextMessage(
        timeout: const Duration(seconds: 8),
      );

      final response = ack == null
          ? -1
          : PairingMessage.parseResponseField(ack);

      _cleanupSocket();

      if (response != 41) {
        return false;
      }

      await markPaired(ip);
      return true;
    } catch (_) {
      _cleanupSocket();
      return false;
    }
  }

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

  void cancelPairing() => _cleanupSocket();

  void dispose() {
    _cleanupSocket();
  }

  void _attachSocketReader(SecureSocket socket) {
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
        _tryDispatch();
      },
      onError: (_) {},
      onDone: () {},
    );
  }

  void _tryDispatch() {
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
