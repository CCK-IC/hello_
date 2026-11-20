import 'dart:typed_data';

/// Independent frozen-wire fixture; every absent slot remains physically zero.
Uint8List sensorFrame(
    {int kind = 1,
    int rows = 3,
    int mask = 1,
    int sequence = 0xfffffffe,
    int timestamp = 0xfffffff0}) {
  final width = {1: 24, 2: 22, 3: 20}[kind]!;
  final data = ByteData(28 + rows * width * 2);
  data.setUint8(0, 3);
  data.setUint8(1, kind);
  data.setUint8(2, mask);
  data.setUint8(3, rows);
  for (var glove = 0; glove < 2; glove++) {
    if ((mask & (1 << glove)) == 0) continue;
    final m = 4 + glove * 12;
    data.setUint32(m, (sequence + glove * 100) & 0xffffffff, Endian.little);
    data.setUint32(m + 4, timestamp, Endian.little);
    data.setUint16(m + 8, 50 + glove, Endian.little);
    data.setUint8(
        m + 10,
        kind == 1
            ? 9
            : kind == 3
                ? 3
                : 0);
    for (var row = 0; row < rows; row++) {
      final o = 28 + (row * 2 + glove) * width;
      data.setUint8(o, row);
      data.setUint16(o + 1, row * 20, Endian.little);
      data.setUint8(
          o + 3,
          kind == 1
              ? 0x7f
              : kind == 2
                  ? 0x1f
                  : 1);
      if (kind == 1) {
        for (var i = 0; i < 10; i++) {
          data.setInt16(
              o + 4 + i * 2, -1000 + i + row * 10 + glove * 100, Endian.little);
        }
      } else if (kind == 2) {
        data.setInt32(o + 4, 1 << 30, Endian.little);
        data.setInt32(o + 8, -(1 << 29), Endian.little);
        data.setInt32(o + 12, -2147483648, Endian.little);
        data.setInt32(o + 16, 2147483647, Endian.little);
        data.setUint16(o + 20, 0xabcd, Endian.little);
      } else {
        for (var i = 0; i < 3; i++) {
          data.setInt16(o + 4 + i * 2, -200 + row * 10 + i, Endian.little);
        }
      }
    }
  }
  return data.buffer.asUint8List();
}

Uint8List statusFrame({int mask = 1}) {
  final d = ByteData(108);
  d.setUint8(0, 3);
  d.setUint8(1, 4);
  d.setUint8(2, mask);
  d.setUint8(3, 1);
  for (var glove = 0; glove < 2; glove++) {
    if ((mask & (1 << glove)) == 0) continue;
    final o = 4 + glove * 52;
    d.setUint32(o, 0xfedcba98, Endian.little);
    for (final entry in {4: 200, 6: 199, 8: 50, 10: 3712, 12: 247}.entries) {
      d.setUint16(o + entry.key, entry.value, Endian.little);
    }
    for (final entry in {
      14: glove + 1,
      15: 3,
      16: 87,
      17: 0xa5,
      18: 1,
      19: 4,
      20: 0,
      21: 2
    }.entries) {
      d.setUint8(o + entry.key, entry.value);
    }
    d.setUint16(o + 22, 3, Endian.little);
    for (final entry in {
      24: 123456,
      28: 123,
      32: 456,
      36: 789,
      40: 234,
      44: 0xf1234567
    }.entries) {
      d.setUint32(o + entry.key, entry.value, Endian.little);
    }
    d.setInt32(o + 48, -12345, Endian.little);
  }
  return d.buffer.asUint8List();
}

List<Uint8List> fragments(Uint8List frame,
    {int payloadSize = 12, int id = 65535}) {
  final count = (frame.length + payloadSize - 1) ~/ payloadSize;
  return List.generate(count, (index) {
    final start = index * payloadSize;
    final end = (start + payloadSize).clamp(0, frame.length);
    final d = ByteData(8 + end - start);
    d.setUint8(0, 0xf3);
    d.setUint8(1, frame[1]);
    d.setUint16(2, id, Endian.little);
    d.setUint8(4, index);
    d.setUint8(5, count);
    d.setUint16(6, frame.length, Endian.little);
    final bytes = d.buffer.asUint8List();
    bytes.setRange(8, bytes.length, frame, start);
    return bytes;
  });
}
