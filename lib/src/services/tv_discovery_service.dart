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

    // 1) Standard Android TV mDNS discovery.
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
                port: event.service.port == 0
                    ? 6466
                    : event.service.port,
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
      // Do not fail the whole search. The subnet fallback below
      // can still find the X96 even if mDNS is blocked/broken.
    }

    // 2) Fallback: scan the current Wi-Fi /24 subnet for the
    // Android TV Remote Service command port (6466).
    // This avoids relying only on multicast/mDNS.
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

      for (final prefix in prefixes) {
        if (_stopped) return;
        await _scan24(prefix);
      }
    } catch (_) {
      // mDNS may still succeed, and manual IP remains available.
    }
  }

  Future<void> _scan24(String prefix) async {
    const batchSize = 32;

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

    Socket? socket;
    try {
      socket = await Socket.connect(
        ip,
        6466,
        timeout: const Duration(milliseconds: 180),
      );

      _addDevice(
        RemoteDevice(
          name: 'X96 / Android TV',
          host: ip,
          port: 6466,
        ),
      );
    } catch (_) {
      // No Android TV Remote Service on this address.
    } finally {
      socket?.destroy();
    }
  }

  void _addDevice(RemoteDevice device) {
    if (_stopped) return;

    // Key by IP so an mDNS result can replace the generic
    // subnet-scan result for the same device.
    final existing = _devices[device.host];

    if (existing == null ||
        existing.name == 'X96 / Android TV') {
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

    // Bonsoir can occasionally return a hostname instead of an IP.
    // Keep it as-is; Dart can resolve .local hostnames on many devices.
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
