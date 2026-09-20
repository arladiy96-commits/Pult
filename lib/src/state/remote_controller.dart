import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../model/remote_device.dart';
import '../model/remote_protocol.dart';
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
  StreamSubscription<List<RemoteDevice>>? _subscription;
  RemoteDevice? _activeDevice;
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

  Future<void> _requestLocalNetworkPermissions() async {
    if (!Platform.isAndroid) return;

    await Permission.nearbyWifiDevices.request();
    await Permission.locationWhenInUse.request();
  }

  Future<void> scan() async {
    _client?.dispose();
    _client = null;

    _security.cancelPairing();
    _activeDevice = null;

    await _subscription?.cancel();
    state = const Scanning();

    try {
      await _requestLocalNetworkPermissions();
      await _certificates.ensureReady();

      _subscription =
          _discovery.discoveredDevices.listen((devices) {
        if (!_disposed && state is Scanning) {
          state = Scanning(devices: devices);
        }
      });

      await _discovery.startDiscovery();
    } catch (e) {
      if (!_disposed) {
        state = Disconnected(
          'Не удалось запустить поиск в локальной сети: $e',
        );
      }
    }
  }

  Future<void> connect(RemoteDevice device) async {
    _activeDevice = device;
    await _discovery.stopDiscovery();

    state = Connecting(device);

    final paired =
        await _security.hasPairedStorage(device.host);

    if (paired) {
      final storedProtocol =
          await _security.protocolFor(device.host);

      if (storedProtocol != null) {
        // A TV can take a moment to reopen its remote-control service
        // after waking or after the app reconnects. A single failed
        // socket attempt must NOT erase a valid pairing.
        for (var attempt = 0; attempt < 3; attempt++) {
          final ok = await _connectCommand(
            device,
            storedProtocol,
          );
          if (ok) return;

          if (attempt < 2) {
            await Future<void>.delayed(
              const Duration(milliseconds: 700),
            );
          }
        }
      }

      // Keep the certificate and pairing marker. If the TV really asks
      // to pair again, we can reuse the same identity instead of
      // destroying a valid pairing after one transient failure.
    }

    final error =
        await _security.initiatePairing(device.host);

    if (error == null) {
      state = PairingRequired(
        device,
        pinLength: _security.currentPinLength,
      );
    } else {
      state = Disconnected(error);
    }
  }

  Future<void> connectManual(String rawIp) async {
    await _requestLocalNetworkPermissions();

    final ip = rawIp.trim();

    final valid = RegExp(
      r'^(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}'
      r'(?:25[0-5]|2[0-4]\d|1?\d?\d)$',
    ).hasMatch(ip);

    if (!valid) {
      state = const Disconnected(
        'Неверный IP. Пример: 192.168.1.120',
      );
      return;
    }

    await connect(
      RemoteDevice(
        name: 'X96 Max Plus',
        host: ip,
      ),
    );
  }

  Future<void> submitPin(String pin) async {
    final device = _activeDevice;
    final protocol = _security.currentProtocol;

    if (device == null || protocol == null) return;

    final pinLength = protocol.pinLength;

    state = Connecting(device);

    final success =
        await _security.sendPinChallenge(
      device.host,
      pin,
    );

    if (!success) {
      state = PairingRequired(
        device,
        pinLength: pinLength,
        error:
            'X96 отклонила код. Введи код с экрана телевизора ещё раз.',
      );
      return;
    }

    // The command service can reopen a fraction of a second after
    // pairing. Retry instead of immediately reporting a failure.
    for (var attempt = 0; attempt < 4; attempt++) {
      final connected = await _connectCommand(
        device,
        protocol,
      );

      if (connected) {
        return;
      }

      if (attempt < 3) {
        await Future<void>.delayed(
          const Duration(milliseconds: 700),
        );
      }
    }

    state = const Disconnected(
      'Pairing подтверждён, но X96 пока не открыла канал управления.',
    );
  }

  Future<bool> _connectCommand(
    RemoteDevice device,
    TVRemoteProtocol protocol,
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

    final ok = await client.connect(
      device.host,
      port: device.port,
      protocol: protocol,
    );

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
