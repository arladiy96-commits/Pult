import 'dart:async';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/certificate_manager.dart';
import '../services/tv_discovery_service.dart';
import '../services/tv_remote_client.dart';
import '../services/tv_security_manager.dart';
import 'remote_state.dart';

final remoteControllerProvider =
    NotifierProvider<RemoteController, RemoteState>(
  RemoteController.new,
);

class RemoteController extends Notifier<RemoteState> {
  late final CertificateManager _certificates;
  late final TVDiscoveryService _discovery;
  late final TVSecurityManager _security;

  TVRemoteClient? _client;
  StreamSubscription<List<BonsoirService>>? _subscription;
  BonsoirService? _activeDevice;
  bool _disposed = false;

  @override
  RemoteState build() {
    _certificates = CertificateManager();
    _discovery = TVDiscoveryService();
    _security = TVSecurityManager(
      certManager: _certificates,
    );

    ref.onDispose(() {
      _disposed = true;
      _subscription?.cancel();
      _discovery.dispose();
      _security.dispose();
      _client?.dispose();
    });

    Future.microtask(scan);
    return const Scanning();
  }

  Future<void> scan() async {
    _client?.dispose();
    _client = null;

    _security.cancelPairing();
    _activeDevice = null;

    await _subscription?.cancel();
    state = const Scanning();

    _subscription =
        _discovery.discoveredServices.listen((devices) {
      if (!_disposed && state is Scanning) {
        state = Scanning(devices: devices);
      }
    });

    try {
      await _certificates.ensureReady();
      await _discovery.startDiscovery();
    } catch (e) {
      if (!_disposed) {
        state = Disconnected(
          'Не удалось запустить поиск в Wi‑Fi сети: $e',
        );
      }
    }
  }

  Future<void> connect(BonsoirService device) async {
    final host = device.host;

    if (host == null || host.isEmpty) {
      state = const Disconnected(
        'У приставки не определился IP-адрес.',
      );
      return;
    }

    _activeDevice = device;
    await _discovery.stopDiscovery();

    state = Connecting(device);

    final paired =
        await _security.hasPairedStorage(host);

    if (paired) {
      final ok = await _connectCommand(device, host);

      if (ok) return;

      await _security.clearPairing(host);
    }

    final error =
        await _security.initiatePairing(host);

    if (error == null) {
      state = PairingRequired(device);
    } else {
      state = Disconnected(error);
    }
  }

  Future<void> submitPin(String pin) async {
    final device = _activeDevice;
    final host = device?.host;

    if (device == null || host == null) return;

    state = Connecting(device);

    final success =
        await _security.sendPinChallenge(host, pin);

    if (!success) {
      state = PairingRequired(
        device,
        error:
            'Код не подошёл. Введи 6 символов с экрана ТВ.',
      );
      return;
    }

    final connected =
        await _connectCommand(device, host);

    if (!connected) {
      state = const Disconnected(
        'Pairing прошёл, но канал управления не открылся.',
      );
    }
  }

  Future<bool> _connectCommand(
    BonsoirService device,
    String host,
  ) async {
    _client?.dispose();

    final client = TVRemoteClient(
      certManager: _certificates,
      onDisconnected: (reason) {
        if (!_disposed) {
          state = Disconnected(reason);
        }
      },
    );

    _client = client;
    final ok = await client.connect(host);

    if (ok && !_disposed) {
      state = Connected(device);
      return true;
    }

    return false;
  }

  void sendKey(int keyCode) {
    _client?.sendKeyPress(keyCode);
  }

  void startRepeat(int keyCode) {
    _client?.startRepeat(keyCode);
  }

  void stopRepeat() {
    _client?.stopRepeat();
  }

  Future<void> forgetAndScan() async {
    final host = _activeDevice?.host;
    if (host != null) {
      await _security.clearPairing(host);
    }
    await scan();
  }
}
