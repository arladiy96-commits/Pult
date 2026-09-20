import '../model/remote_device.dart';

sealed class RemoteState {
  const RemoteState();
}

class Scanning extends RemoteState {
  final List<RemoteDevice> devices;

  const Scanning({
    this.devices = const [],
  });
}

class Connecting extends RemoteState {
  final RemoteDevice device;

  const Connecting(this.device);
}

class PairingRequired extends RemoteState {
  final RemoteDevice device;
  final int pinLength;
  final String? error;

  const PairingRequired(
    this.device, {
    required this.pinLength,
    this.error,
  });
}

class Connected extends RemoteState {
  final RemoteDevice device;

  const Connected(this.device);
}

class Disconnected extends RemoteState {
  final String reason;

  const Disconnected(this.reason);
}
