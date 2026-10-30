import 'dart:typed_data';

import 'package:ble_imu_visualizer/models/ble_stream_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List packet(int sequence) {
  final data = ByteData(20);
  data.setUint8(0, 2);
  data.setUint16(2, sequence, Endian.little);
  return data.buffer.asUint8List();
}

void main() {
  test('counts notifications, missing sequences, wrap and invalid payloads', () {
    final diagnostics = BleStreamDiagnostics();
    final now = DateTime.utc(2026, 10, 30);
    diagnostics.record(packet(65534), now);
    diagnostics.record(packet(0), now);
    diagnostics.record(packet(0), now);
    diagnostics.record(Uint8List(0), now);

    expect(diagnostics.packets, 4);
    expect(diagnostics.invalidPackets, 1);
    expect(diagnostics.sequenceGaps, 1);
    expect(diagnostics.repeatedOrOlder, 1);
    expect(diagnostics.describe(now.add(const Duration(seconds: 3))),
        contains('lastPacketAge=3000ms'));

    diagnostics.reset();
    expect(diagnostics.packets, 0);
    expect(diagnostics.lastPacket, isNull);
  });
}
