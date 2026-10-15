import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Authenticated, certificate-pinned local connection to Pult-TV.
/// The saved token is never sent before the TV certificate has been verified.
class TvCompanionClient {
  TvCompanionClient(this.host);

  final String host;
  static const port = 39678;
  final _vault = const FlutterSecureStorage();
  final _pending = Queue<Completer<Map<String, dynamic>>>();
  final _changes = StreamController<bool>.broadcast();
  SecureSocket? _socket;
  StreamSubscription<String>? _subscription;
  Future<void>? _reconnecting;
  bool _authenticated = false;
  bool _disposed = false;

  Stream<bool> get connectionChanges => _changes.stream;
  bool get isConnected => _authenticated && _socket != null;
  String get _storagePrefix => 'tv_companion_$host';

  Future<({String fingerprint, String token})?> storedIdentity() async {
    final fingerprint = await _vault.read(key: '${_storagePrefix}_sha256');
    final token = await _vault.read(key: '${_storagePrefix}_token');
    if (fingerprint == null || token == null) return null;
    return (fingerprint: fingerprint, token: token);
  }

  /// Unauthenticated certificate discovery: must be compared with the TV display.
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
    if (_disposed) throw StateError('Клиент закрыт');
    final expected = expectedSha256.replaceAll(':', '').toUpperCase();
    if (!RegExp(r'^[A-F0-9]{64}$').hasMatch(expected)) {
      throw const FormatException('Неправильный SHA-256 сертификата');
    }
    final socket = await SecureSocket.connect(
      host, port,
      timeout: const Duration(seconds: 6),
      onBadCertificate: (cert) =>
          sha256.convert(cert.der).toString().toUpperCase() == expected,
    );
    final cert = socket.peerCertificate;
    if (cert == null ||
        sha256.convert(cert.der).toString().toUpperCase() != expected) {
      socket.destroy();
      throw const HandshakeException('Сертификат приставки изменился');
    }
    if (_disposed) {
      socket.destroy();
      throw StateError('Клиент закрыт');
    }
    socket.setOption(SocketOption.tcpNoDelay, true);
    _socket = socket;
    _subscription = socket
        .map<List<int>>((bytes) => bytes)
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (_pending.isEmpty) return;
      final reply = _pending.removeFirst();
      if (reply.isCompleted) return;
      try {
        final data = jsonDecode(line);
        if (data is! Map<String, dynamic>) {
          throw const FormatException('Неверный ответ приставки');
        }
        reply.complete(data);
      } catch (e) {
        reply.completeError(e);
      }
    }, onError: (Object e) => _disconnectIfCurrent(socket, e),
        onDone: () => _disconnectIfCurrent(
          socket, const SocketException('Соединение с приставкой закрыто')));
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
      _setAuthenticated(true);
    } catch (_) {
      close();
      rethrow;
    }
  }

  Future<void> connectSaved() async {
    final current = _reconnecting;
    if (current != null) return current;
    final future = _connectSavedOnce();
    _reconnecting = future;
    try {
      await future;
    } finally {
      if (identical(_reconnecting, future)) _reconnecting = null;
    }
  }

  Future<void> _connectSavedOnce() async {
    final identity = await storedIdentity();
    if (identity == null) throw StateError('Нет сопряжения с приставкой');
    await _connectPinned(identity.fingerprint);
    try {
      final reply = await request({'cmd': 'auth', 'token': identity.token});
      if (reply['ok'] != true) {
        throw StateError('${reply['error'] ?? 'Не удалось подключиться'}');
      }
      _setAuthenticated(true);
    } catch (_) {
      close();
      rethrow;
    }
  }

  /// Non-replayed request: if delivery is uncertain, retrying a click may click twice.
  /// On timeout the TCP stream is discarded so late responses cannot mismatch
  /// later commands.
  Future<Map<String, dynamic>> request(Map<String, dynamic> message,
      {Duration timeout = const Duration(seconds: 7)}) async {
    final socket = _socket;
    if (socket == null) {
      throw const SocketException('Нет соединения с приставкой');
    }
    final answer = Completer<Map<String, dynamic>>();
    _pending.add(answer);
    try {
      socket.add(utf8.encode('${jsonEncode(message)}\n'));
    } catch (e) {
      _disconnectIfCurrent(socket, e);
      rethrow;
    }
    try {
      return await answer.future.timeout(timeout);
    } on TimeoutException {
      _disconnectIfCurrent(socket, const SocketException('Приставка не отвечает'));
      rethrow;
    }
  }

  /// Called after returning from background or by foreground keepalive.
  /// A failed ping results in a fresh pinned TLS connection, without a new PIN.
  Future<void> ensureConnected() async {
    if (!isConnected) {
      await connectSaved();
      return;
    }
    try {
      final reply = await request({'cmd': 'ping'}, timeout: const Duration(seconds: 3));
      if (reply['ok'] != true) throw const SocketException('Нет ответа от приставки');
    } catch (_) {
      close();
      await connectSaved();
    }
  }

  void _disconnectIfCurrent(SecureSocket socket, Object reason) {
    if (!identical(_socket, socket)) return;
    close(reason: reason);
  }

  void _setAuthenticated(bool value) {
    if (_authenticated == value) return;
    _authenticated = value;
    if (!_changes.isClosed) _changes.add(value);
  }

  void _failPending(Object reason) {
    while (_pending.isNotEmpty) {
      final pending = _pending.removeFirst();
      if (!pending.isCompleted) pending.completeError(reason);
    }
  }

  Future<void> forget() async {
    close();
    await _vault.delete(key: '${_storagePrefix}_sha256');
    await _vault.delete(key: '${_storagePrefix}_token');
  }

  void close({Object reason = const SocketException('Соединение закрыто')}) {
    _setAuthenticated(false);
    _subscription?.cancel();
    _subscription = null;
    _socket?.destroy();
    _socket = null;
    _failPending(reason);
  }

  void dispose() {
    _disposed = true;
    close();
    _changes.close();
  }
}
