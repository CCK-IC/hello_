import 'dart:typed_data';

import 'package:ble_imu_visualizer/models/ble_stream_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ble_imu_visualizer/models/protocol.dart';

import 'batch_test_fixtures.dart';

Uint8List packet(int sequence) {
  final data = ByteData(20);
  data.setUint8(0, 2);
  data.setUint16(2, sequence, Endian.little);
  return data.buffer.asUint8List();
}

void main() {
  test(
      'counts fragments as notifications and complete frames/samples separately',
      () {
    final d = BleStreamDiagnostics();
    final now = DateTime.utc(2026);
    d.recordNotification(now);
    d.recordNotification(now);
    d.recordNotification(now);
    expect(d.packets, 3);
    expect(d.frames, 0);
    expect(d.samples, 0);
    d.recordFrame(RawImuSample.decodeAll(sensorFrame(mask: 3))!);
    expect(d.packets, 3);
    expect(d.frames, 1);
    expect(d.samples, 6);
    expect(d.sequenceGaps, 0);
    expect(d.repeatedOrOlder, 0);
    d.recordFrame(
        RawImuSample.decodeAll(sensorFrame(mask: 3, rows: 1, sequence: 2))!);
    expect(d.sequenceGaps, 2); // One missing record for each independent glove.
    d.recordFrame(
        RawImuSample.decodeAll(sensorFrame(mask: 3, rows: 1, sequence: 2))!);
    expect(d.repeatedOrOlder, 2);
    d.recordMalformed();
    expect(d.invalidPackets, 1);
    expect(d.describe(now), contains('packets=3 frames=3 samples=10'));
    d.reset();
    expect([
      d.packets,
      d.frames,
      d.samples,
      d.sequenceGaps,
      d.repeatedOrOlder,
      d.invalidPackets
    ], List.filled(6, 0));
    d.record(sensorFrame(), now);
    expect([d.packets, d.frames, d.samples, d.invalidPackets], [1, 1, 3, 0]);
  });

  test('malformed late rows do not emit diagnostic samples or alter ordering',
      () {
    final d = BleStreamDiagnostics();
    final now = DateTime.utc(2026);
    d.record(sensorFrame(rows: 1, sequence: 5), now);
    final bad = sensorFrame(sequence: 6)..[28 + 4 * 24 + 3] = 128;
    d.record(bad, now);
    expect([d.packets, d.frames, d.samples, d.invalidPackets], [2, 1, 1, 1]);
    d.record(sensorFrame(rows: 1, sequence: 7), now);
    expect(d.sequenceGaps, 1);
  });

  test('counts notifications, missing sequences, wrap and invalid payloads',
      () {
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
