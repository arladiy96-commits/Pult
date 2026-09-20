import 'dart:async';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';

import '../model/remote_device.dart';

class TVDiscoveryService {
  static const _serviceType = '_androidtvremote2._tcp';

  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _subscription;

  final Map<String, RemoteDevice> _devices = {};
  final _controller =
      StreamController<List<RemoteDevice>>.broadcast();

  Stream<List<RemoteDevice>> get discoveredDevices =>
      _controller.stream;

  bool _stopped = false;

  Future<void> startDiscovery() async {
    await stopDiscovery();

    _stopped = false;
    _devices.clear();
    _controller.add(const []);

    // 1) Standard Android TV Remote Service discovery via mDNS.
    try {
      final discovery = BonsoirDiscovery(type: _serviceType);
      _discovery = discovery;
      await discovery.initialize();

      _subscription = discovery.eventStream?.listen((event) {
        switch (event) {
          case BonsoirDiscoveryServiceFoundEvent():
            discovery.serviceResolver.resolveService(event.service);

          case BonsoirDiscoveryServiceResolvedEvent():
            final host = event.service.host;
            if (host == null || host.trim().isEmpty) return;

            _addDevice(
              RemoteDevice(
                name: event.service.name,
                host: _normalizeHost(host),
                // Commands normally use 6466.
                port: 6466,
              ),
            );

          case BonsoirDiscoveryServiceLostEvent():
            final name = event.service.name;
            _devices.removeWhere(
              (_, value) => value.name == name,
            );
            _emit();

          default:
            break;
        }
      });

      await discovery.start();
    } catch (_) {
      // Continue with direct subnet scan below.
    }

    // 2) Fallback: scan the current Wi-Fi subnet directly.
    // We test BOTH standard Android TV Remote ports:
    // 6467 = pairing, 6466 = remote commands.
    unawaited(_scanLocalSubnets());
  }

  Future<void> _scanLocalSubnets() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );

      final prefixes = <String>{};

      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          final ip = address.address;
          final parts = ip.split('.');
          if (parts.length != 4) continue;
          if (!_isPrivateIpv4(parts)) continue;

          prefixes.add('${parts[0]}.${parts[1]}.${parts[2]}');
        }
      }

      // Normal path: scan the subnet(s) the phone is actually on.
      for (final prefix in prefixes) {
        if (_stopped) return;
        await _scan24(prefix);
      }

      // Extra fallback for common home-router ranges if Android did not
      // expose a useful Wi-Fi IPv4 interface for some reason.
      if (prefixes.isEmpty) {
        for (final prefix in const [
          '192.168.0',
          '192.168.1',
        ]) {
          if (_stopped) return;
          await _scan24(prefix);
        }
      }
    } catch (_) {
      // mDNS and manual IP are still available.
    }
  }

  Future<void> _scan24(String prefix) async {
    const batchSize = 24;

    for (var start = 1; start <= 254; start += batchSize) {
      if (_stopped) return;

      final futures = <Future<void>>[];

      for (var i = start;
          i < start + batchSize && i <= 254;
          i++) {
        futures.add(_probeHost('$prefix.$i'));
      }

      await Future.wait(futures);
    }
  }

  Future<void> _probeHost(String ip) async {
    if (_stopped) return;

    // Pairing port first: an unpaired Android TV may expose 6467
    // even when 6466 is not accepting a normal remote session yet.
    final pairingOpen = await _isPortOpen(ip, 6467);

    if (pairingOpen) {
      _addDevice(
        RemoteDevice(
          name: 'Android TV / X96',
          host: ip,
          port: 6466,
        ),
      );
      return;
    }

    final remoteOpen = await _isPortOpen(ip, 6466);

    if (remoteOpen) {
      _addDevice(
        RemoteDevice(
          name: 'Android TV / X96',
          host: ip,
          port: 6466,
        ),
      );
    }
  }

  Future<bool> _isPortOpen(String ip, int port) async {
    Socket? socket;

    try {
      socket = await Socket.connect(
        ip,
        port,
        timeout: const Duration(milliseconds: 350),
      );
      return true;
    } catch (_) {
      return false;
    } finally {
      socket?.destroy();
    }
  }

  void _addDevice(RemoteDevice device) {
    if (_stopped) return;

    final existing = _devices[device.host];

    // Prefer the real mDNS name over the generic scan name.
    if (existing == null ||
        existing.name == 'Android TV / X96') {
      _devices[device.host] = device;
      _emit();
    }
  }

  void _emit() {
    if (!_controller.isClosed) {
      _controller.add(
        _devices.values.toList()
          ..sort((a, b) => a.name.compareTo(b.name)),
      );
    }
  }

  String _normalizeHost(String host) {
    var value = host.trim();

    if (value.endsWith('.')) {
      value = value.substring(0, value.length - 1);
    }

    return value;
  }

  bool _isPrivateIpv4(List<String> parts) {
    final a = int.tryParse(parts[0]) ?? -1;
    final b = int.tryParse(parts[1]) ?? -1;

    if (a == 10) return true;
    if (a == 192 && b == 168) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;

    return false;
  }

  Future<void> stopDiscovery() async {
    _stopped = true;

    await _subscription?.cancel();
    _subscription = null;

    await _discovery?.stop();
    _discovery = null;
  }

  Future<void> dispose() async {
    await stopDiscovery();
    await _controller.close();
  }
}
