import 'package:bonsoir/bonsoir.dart';

sealed class RemoteState {
  const RemoteState();
}

class Scanning extends RemoteState {
  final List<BonsoirService> devices;

  const Scanning({
    this.devices = const [],
  });
}

class Connecting extends RemoteState {
  final BonsoirService device;

  const Connecting(this.device);
}

class PairingRequired extends RemoteState {
  final BonsoirService device;
  final String? error;

  const PairingRequired(
    this.device, {
    this.error,
  });
}

class Connected extends RemoteState {
  final BonsoirService device;

  const Connected(this.device);
}

class Disconnected extends RemoteState {
  final String reason;

  const Disconnected(this.reason);
}
