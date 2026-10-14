import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// TLS/pinned-certificate client for the optional Android TV-side companion.
/// No PIN or trust token is ever sent during an unauthenticated fingerprint probe.
class TvCompanionClient {
  TvCompanionClient(this.host);

  final String host;
  static const port = 39678;
  final _vault = const FlutterSecureStorage();
  SecureSocket? _socket;
  StreamSubscription<String>? _subscription;
  final Queue<Completer<Map<String, dynamic>>> _pending = Queue();
  bool _closed = false;

  String get _storagePrefix => 'tv_companion_$host';

  Future<({String fingerprint, String token})?> storedIdentity() async {
    final fingerprint = await _vault.read(key: '${_storagePrefix}_sha256');
    final token = await _vault.read(key: '${_storagePrefix}_token');
    if (fingerprint == null || token == null) return null;
    return (fingerprint: fingerprint, token: token);
  }

  /// Untrusted discovery; display the result and require physical comparison on TV.
  Future<String> probeFingerprint() async {
    final socket = await SecureSocket.connect(
      host, port,
      timeout: const Duration(seconds: 6),
      onBadCertificate: (_) => true,
    );
    try {
      final der = socket.peerCertificate?.der;
      if (der == null) throw const SocketException('Сертификат не получен');
      return sha256.convert(der).toString().toUpperCase();
    } finally {
      socket.destroy();
    }
  }

  Future<void> _connectPinned(String expectedSha256) async {
    close();
    _closed = false;
    final expected = expectedSha256.replaceAll(':', '').toUpperCase();
    if (!RegExp(r'^[A-F0-9]{64}$').hasMatch(expected)) {
      throw const FormatException('Неправильный SHA-256 сертификата');
    }
    final socket = await SecureSocket.connect(
      host, port,
      timeout: const Duration(seconds: 6),
      // This is not blind trust: certificate DER is compared to the TV's PINNED fingerprint.
      onBadCertificate: (cert) =>
          sha256.convert(cert.der).toString().toUpperCase() == expected,
    );
    final cert = socket.peerCertificate;
    if (cert == null || sha256.convert(cert.der).toString().toUpperCase() != expected) {
      socket.destroy();
      throw const HandshakeException('Сертификат приставки изменился');
    }
    _socket = socket;
    _subscription = socket
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (_pending.isEmpty) return;
      final reply = _pending.removeFirst();
      try {
        final data = jsonDecode(line);
        if (data is! Map<String, dynamic>) {
          throw const FormatException('Неверный ответ приставки');
        }
        reply.complete(data);
      } catch (e) {
        reply.completeError(e);
      }
    }, onError: (Object error) => _failPending(error), onDone: () {
      _failPending(const SocketException('Соединение с приставкой закрыто'));
    });
  }

  Future<void> pair(String fingerprint, String pin) async {
    if (!RegExp(r'^\d{6}$').hasMatch(pin)) {
      throw const FormatException('Код должен состоять из шести цифр');
    }
    await _connectPinned(fingerprint);
    try {
      final reply = await request({'cmd': 'pair', 'pin': pin});
      if (reply['ok'] != true || reply['token'] is! String) {
        throw StateError('${reply['error'] ?? 'Ошибка сопряжения'}');
      }
      await _vault.write(key: '${_storagePrefix}_sha256', value: fingerprint);
      await _vault.write(key: '${_storagePrefix}_token', value: reply['token'] as String);
    } catch (_) {
      close();
      rethrow;
    }
  }

  Future<void> connectSaved() async {
    final identity = await storedIdentity();
    if (identity == null) throw StateError('Нет сопряжения с приставкой');
    await _connectPinned(identity.fingerprint);
    try {
      final reply = await request({'cmd': 'auth', 'token': identity.token});
      if (reply['ok'] != true) {
        throw StateError('${reply['error'] ?? 'Не удалось подключиться'}');
      }
    } catch (_) {
      close();
      rethrow;
    }
  }

  Future<Map<String, dynamic>> request(Map<String, dynamic> message) async {
    if (_closed || _socket == null) throw const SocketException('Нет соединения с приставкой');
    final answer = Completer<Map<String, dynamic>>();
    _pending.add(answer);
    try {
      _socket!.add(utf8.encode('${jsonEncode(message)}\n'));
    } catch (e) {
      _failPending(e);
      rethrow;
    }
    return answer.future.timeout(const Duration(seconds: 10));
  }

  void _failPending(Object reason) {
    while (_pending.isNotEmpty) {
      final reply = _pending.removeFirst();
      if (!reply.isCompleted) reply.completeError(reason);
    }
  }

  Future<void> forget() async {
    close();
    await _vault.delete(key: '${_storagePrefix}_sha256');
    await _vault.delete(key: '${_storagePrefix}_token');
  }

  void close() {
    _closed = true;
    _subscription?.cancel();
    _subscription = null;
    _socket?.destroy();
    _socket = null;
    _failPending(const SocketException('Соединение закрыто'));
  }
}
