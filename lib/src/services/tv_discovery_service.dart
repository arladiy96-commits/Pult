import 'dart:async';

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

  Future<void> startDiscovery() async {
    await stopDiscovery();

    _devices.clear();
    _controller.add(const []);

    final discovery = BonsoirDiscovery(
      type: _serviceType,
      printLogs: true,
    );

    _discovery = discovery;
    await discovery.initialize();

    _subscription = discovery.eventStream?.listen(
      (event) {
        switch (event) {
          case BonsoirDiscoveryServiceFoundEvent():
            discovery.serviceResolver.resolveService(
              event.service,
            );

          case BonsoirDiscoveryServiceResolvedEvent():
            final host = event.service.host;
            if (host == null || host.trim().isEmpty) return;

            _devices[event.service.name] = RemoteDevice(
              name: event.service.name,
              host: host,
              port: event.service.port == 0
                  ? 6466
                  : event.service.port,
            );
            _controller.add(_devices.values.toList());

          case BonsoirDiscoveryServiceLostEvent():
            _devices.remove(event.service.name);
            _controller.add(_devices.values.toList());

          default:
            break;
        }
      },
      onError: (Object error, StackTrace stack) {
        // Keep discovery alive; manual IP remains available.
      },
    );

    await discovery.start();
  }

  Future<void> stopDiscovery() async {
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
