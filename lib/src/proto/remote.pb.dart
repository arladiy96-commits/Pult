import 'dart:convert';
import 'dart:typed_data';

List<int> _varint(int v) {
  final out = <int>[];
  while (v > 0x7F) {
    out.add((v & 0x7F) | 0x80);
    v >>= 7;
  }
  out.add(v);
  return out;
}

List<int> _int32Field(int field, int v) =>
    [..._varint((field << 3) | 0), ..._varint(v)];

List<int> _bytesField(int field, List<int> data) =>
    [..._varint((field << 3) | 2), ..._varint(data.length), ...data];

List<int> _strField(int field, String s) =>
    _bytesField(field, utf8.encode(s));

Uint8List frameMessage(List<int> proto) {
  final prefix = _varint(proto.length);
  final frame = Uint8List(prefix.length + proto.length);
  frame.setRange(0, prefix.length, prefix);
  frame.setRange(prefix.length, frame.length, proto);
  return frame;
}

class RemoteDirection {
  static const int startLong = 1;
  static const int endLong = 2;
  static const int short = 3;
}

class PairingMessage {
  static List<int> _header() => [
        ..._int32Field(1, 2),
        ..._int32Field(2, 200),
      ];

  static Uint8List buildRequest({
    required String serviceName,
    required String clientName,
  }) {
    final inner = [
      ..._strField(1, serviceName),
      ..._strField(2, clientName),
    ];
    return frameMessage([..._header(), ..._bytesField(10, inner)]);
  }

  static Uint8List buildOptions() {
    final encoding = [
      ..._int32Field(1, 3),
      ..._int32Field(2, 6),
    ];
    final inner = [
      ..._bytesField(1, encoding),
      ..._int32Field(3, 1),
    ];
    return frameMessage([..._header(), ..._bytesField(20, inner)]);
  }

  static Uint8List buildConfiguration() {
    final encoding = [
      ..._int32Field(1, 3),
      ..._int32Field(2, 6),
    ];
    final inner = [
      ..._bytesField(1, encoding),
      ..._int32Field(2, 1),
    ];
    return frameMessage([..._header(), ..._bytesField(30, inner)]);
  }

  static Uint8List buildSecret(List<int> secretBytes) =>
      frameMessage([
        ..._header(),
        ..._bytesField(40, _bytesField(1, secretBytes)),
      ]);

  static int parseResponseField(Uint8List data) {
    int i = 0;
    int result = -1;
    int status = -1;

    while (i < data.length) {
      int tag = 0;
      int shift = 0;
      while (i < data.length) {
        final b = data[i++];
        tag |= (b & 0x7F) << shift;
        if ((b & 0x80) == 0) break;
        shift += 7;
      }

      final field = tag >> 3;
      final wireType = tag & 7;

      if (wireType == 0) {
        int value = 0;
        shift = 0;
        while (i < data.length) {
          final b = data[i++];
          value |= (b & 0x7F) << shift;
          if ((b & 0x80) == 0) break;
          shift += 7;
        }
        if (field == 2) status = value;
      } else if (wireType == 2) {
        int len = 0;
        shift = 0;
        while (i < data.length) {
          final b = data[i++];
          len |= (b & 0x7F) << shift;
          if ((b & 0x80) == 0) break;
          shift += 7;
        }
        if (field >= 10) result = field;
        i += len;
        if (i > data.length) return -1;
      } else {
        return -1;
      }
    }

    if (status != -1 && status != 200) return -2;
    return result;
  }
}

class RemoteMessage {
  static Uint8List buildPingResponse(int val1) =>
      frameMessage(_bytesField(9, _int32Field(1, val1)));

  static Uint8List buildConfigure() {
    final deviceInfo = [
      ..._strField(1, 'X96 Remote'),
      ..._strField(2, 'Local Remote'),
      ..._int32Field(3, 1),
      ..._strField(4, '1'),
      ..._strField(5, 'app.x96remote'),
      ..._strField(6, '0.1.0'),
    ];
    return frameMessage(
      _bytesField(
        1,
        [
          ..._int32Field(1, 622),
          ..._bytesField(2, deviceInfo),
        ],
      ),
    );
  }

  static Uint8List buildSetActive() =>
      frameMessage(_bytesField(2, _int32Field(1, 622)));

  static Uint8List buildKeyInject(int keyCode, int direction) =>
      frameMessage(
        _bytesField(
          10,
          [
            ..._int32Field(1, keyCode),
            ..._int32Field(2, direction),
          ],
        ),
      );

  static Uint8List buildAppLink(String appLink) =>
      frameMessage(
        _bytesField(
          90,
          _strField(1, appLink),
        ),
      );

  static Uint8List buildImeBatchEdit({
    required int imeCounter,
    required int fieldCounter,
    required String text,
  }) {
    final imeObject = [
      ..._int32Field(1, text.isEmpty ? 0 : text.length - 1),
      ..._int32Field(2, text.isEmpty ? 0 : text.length - 1),
      ..._strField(3, text),
    ];

    final editInfo = [
      ..._int32Field(1, 1),
      ..._bytesField(2, imeObject),
    ];

    final batch = [
      ..._int32Field(1, imeCounter),
      ..._int32Field(2, fieldCounter),
      ..._bytesField(3, editInfo),
    ];

    return frameMessage(_bytesField(21, batch));
  }

  static RemoteIncoming parse(Uint8List data) {
    int i = 0;

    while (i < data.length) {
      int tag = 0;
      int shift = 0;

      while (i < data.length) {
        final b = data[i++];
        tag |= (b & 0x7F) << shift;
        if ((b & 0x80) == 0) break;
        shift += 7;
      }

      final field = tag >> 3;
      final wireType = tag & 7;

      if (wireType == 0) {
        while (i < data.length) {
          if ((data[i++] & 0x80) == 0) break;
        }
      } else if (wireType == 2) {
        int len = 0;
        shift = 0;

        while (i < data.length) {
          final b = data[i++];
          len |= (b & 0x7F) << shift;
          if ((b & 0x80) == 0) break;
          shift += 7;
        }

        if (i + len > data.length) return const RemoteIncoming(field: -1);

        final payload = Uint8List.fromList(
          data.sublist(i, i + len),
        );

        if (field == 8) {
          final pingVal = _firstVarintValue(payload);
          return RemoteIncoming(field: 8, pingVal: pingVal);
        }

        if (field == 21) {
          final counters = _readFirstTwoVarints(payload);
          return RemoteIncoming(
            field: 21,
            imeCounter: counters.$1,
            imeFieldCounter: counters.$2,
          );
        }

        return RemoteIncoming(field: field);
      } else {
        break;
      }
    }

    return const RemoteIncoming(field: -1);
  }

  static (int, int) _readFirstTwoVarints(Uint8List data) {
    int i = 0;
    int first = 0;
    int second = 0;

    while (i < data.length) {
      int tag = 0;
      int shift = 0;
      while (i < data.length) {
        final b = data[i++];
        tag |= (b & 0x7F) << shift;
        if ((b & 0x80) == 0) break;
        shift += 7;
      }

      final field = tag >> 3;
      final wire = tag & 7;
      if (wire != 0) break;

      int value = 0;
      shift = 0;
      while (i < data.length) {
        final b = data[i++];
        value |= (b & 0x7F) << shift;
        if ((b & 0x80) == 0) break;
        shift += 7;
      }

      if (field == 1) first = value;
      if (field == 2) second = value;
      if (first != 0 && second != 0) break;
    }

    return (first, second);
  }

  static int _firstVarintValue(Uint8List data) {
    int i = 0;
    while (i < data.length && (data[i++] & 0x80) != 0) {}

    int value = 0;
    int shift = 0;

    while (i < data.length) {
      final b = data[i++];
      value |= (b & 0x7F) << shift;
      if ((b & 0x80) == 0) break;
      shift += 7;
    }
    return value;
  }
}

class RemoteIncoming {
  final int field;
  final int pingVal;
  final int imeCounter;
  final int imeFieldCounter;

  const RemoteIncoming({
    required this.field,
    this.pingVal = 0,
    this.imeCounter = 0,
    this.imeFieldCounter = 0,
  });
}
