class RemoteDevice {
  final String name;
  final String host;
  final int port;

  const RemoteDevice({
    required this.name,
    required this.host,
    this.port = 6466,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RemoteDevice &&
          name == other.name &&
          host == other.host &&
          port == other.port;

  @override
  int get hashCode => Object.hash(name, host, port);
}
