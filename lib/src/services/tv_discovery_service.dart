import 'dart:async';

import 'package:bonsoir/bonsoir.dart';

class TVDiscoveryService {
  static const _serviceType = '_androidtvremote2._tcp';

  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _subscription;

  final Map<String, BonsoirService> _services = {};
  final _controller =
      StreamController<List<BonsoirService>>.broadcast();

  Stream<List<BonsoirService>> get discoveredServices =>
      _controller.stream;

  Future<void> startDiscovery() async {
    await stopDiscovery();

    _services.clear();
    _controller.add(const []);

    final discovery = BonsoirDiscovery(type: _serviceType);
    _discovery = discovery;
    await discovery.initialize();

    _subscription = discovery.eventStream?.listen((event) {
      switch (event) {
        case BonsoirDiscoveryServiceFoundEvent():
          discovery.serviceResolver.resolveService(event.service);

        case BonsoirDiscoveryServiceResolvedEvent():
          _services[event.service.name] = event.service;
          _controller.add(_services.values.toList());

        case BonsoirDiscoveryServiceLostEvent():
          _services.remove(event.service.name);
          _controller.add(_services.values.toList());

        default:
          break;
      }
    });

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
