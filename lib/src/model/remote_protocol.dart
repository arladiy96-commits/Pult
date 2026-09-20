enum TVRemoteProtocol {
  legacyV1,
  remoteV2,
}

extension TVRemoteProtocolInfo on TVRemoteProtocol {
  int get pinLength => switch (this) {
        TVRemoteProtocol.legacyV1 => 4,
        TVRemoteProtocol.remoteV2 => 6,
      };

  String get storageValue => switch (this) {
        TVRemoteProtocol.legacyV1 => 'v1',
        TVRemoteProtocol.remoteV2 => 'v2',
      };

  static TVRemoteProtocol? fromStorage(String? value) {
    return switch (value) {
      'v1' => TVRemoteProtocol.legacyV1,
      'v2' => TVRemoteProtocol.remoteV2,
      _ => null,
    };
  }
}
