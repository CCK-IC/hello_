import 'dart:typed_data';

import 'package:ble_imu_visualizer/models/adc_history.dart';
import 'package:ble_imu_visualizer/models/protocol.dart';
import 'package:ble_imu_visualizer/models/raw_imu_history.dart';
import 'package:flutter_test/flutter_test.dart';

import 'batch_test_fixtures.dart';

void main() {
  test(
      'raw v3 reconstructs wrapped sequences/times, signed full values and flags',
      () {
    final bytes = sensorFrame();
    final samples = RawImuSample.decodeAll(bytes)!;
    expect(samples.map((s) => s.sequence), [0xfffffffe, 0xffffffff, 0]);
    expect(samples.map((s) => s.timestampMs), [0xfffffff0, 4, 24]);
    expect(samples.map((s) => s.gloveId), [0, 0, 0]);
    final s = samples.first;
    expect(s.version, 3);
    expect(s.accelerometerRangeCode, 1);
    expect(s.gyroscopeRangeCode, 2);
    expect(s.measuredRateHz, 50);
    expect([
      s.accelerometerX,
      s.accelerometerY,
      s.accelerometerZ,
      s.gyroscopeX,
      s.gyroscopeY,
      s.gyroscopeZ,
      s.magnetometerX,
      s.magnetometerY,
      s.magnetometerZ,
      s.temperature
    ], List.generate(10, (i) => -1000 + i));
    expect(s.accelerometerXG, -1000 / 8192);
    expect(s.gyroscopeXDps, -997 / 32.8);
    expect(
        s.flags.sampleValid &&
            s.flags.accelerometerValid &&
            s.flags.gyroscopeValid &&
            s.flags.magnetometerValid &&
            s.flags.temperatureValid &&
            s.flags.magnetometerOverflow &&
            s.flags.dmpActive,
        isTrue);
    expect(samples.last.isNewerThan(samples[1]), isTrue);
    final p = RawImuHistoryPoint(receivedAt: DateTime.utc(2026), sample: s);
    expect(p.valuesFor(RawSensorType.magnetometer), [-994.0, -993.0, -992.0]);
    expect(RawImuSample.decode(bytes)!.sequence, 0);
  });

  test('paired slots stay in row order and convenience decoders select local',
      () {
    final raw = RawImuSample.decodeAll(sensorFrame(mask: 3))!;
    expect(raw.map((s) => s.gloveId), [0, 1, 0, 1, 0, 1]);
    expect(
        raw.map((s) => s.sequence), [0xfffffffe, 98, 0xffffffff, 99, 0, 100]);
    expect(RawImuSample.decode(sensorFrame(mask: 3))!.gloveId, 0);
    expect(RawImuSample.decode(sensorFrame(mask: 3))!.sequence, 0);
    expect(AdcSample.decode(sensorFrame(kind: 3, mask: 3))!.sequence, 0);
    expect(
        QuaternionSample.decodeAll(sensorFrame(kind: 2, mask: 3))!.length, 6);
    expect(DeviceStatus.decodeAll(statusFrame(mask: 3))!.map((s) => s.gloveId),
        [0, 1]);
    expect(DeviceStatus.decode(statusFrame(mask: 3))!.boardId, 1);
  });

  for (final kind in [1, 2, 3]) {
    List<Object>? decode(Uint8List bytes) => switch (kind) {
          1 => RawImuSample.decodeAll(bytes),
          2 => QuaternionSample.decodeAll(bytes),
          _ => AdcSample.decodeAll(bytes),
        };
    final width = {1: 24, 2: 22, 3: 20}[kind]!;
    test(
        'kind $kind rejects every nonzero absent metadata/payload byte atomically',
        () {
      final original = sensorFrame(kind: kind);
      final offsets = [
        for (var i = 16; i < 28; i++) i,
        for (var row = 0; row < 3; row++)
          for (var i = 0; i < width; i++) 28 + (row * 2 + 1) * width + i
      ];
      for (final offset in offsets) {
        final bad = Uint8List.fromList(original)..[offset] = 1;
        expect(decode(bad), isNull, reason: 'absent byte $offset');
      }
    });
    test('kind $kind strict framing, masks, metadata, flags and row ordering',
        () {
      final original = sensorFrame(kind: kind);
      for (var length = 0; length < original.length; length++) {
        expect(decode(Uint8List.sublistView(original, 0, length)), isNull);
      }
      expect(decode(Uint8List.fromList([...original, 0])), isNull);
      for (final mutation in <int, List<int>>{
        0: [0, 4, 0xf3],
        1: [0, 4],
        2: [0, 2, 4, 0x81, 0xff],
        3: [0, 9],
        15: [1],
        14: kind == 1
            ? [16]
            : kind == 2
                ? [1]
                : [0, 9],
        28: [1],
        29: [1],
        28 + 4 * width: [0, 1],
        28 + 4 * width + 1: [19],
        28 + 4 * width + 3: [
          kind == 1
              ? 128
              : kind == 2
                  ? 32
                  : 2
        ],
      }.entries) {
        for (final value in mutation.value) {
          final bad = Uint8List.fromList(original)..[mutation.key] = value;
          expect(decode(bad), isNull,
              reason: 'offset ${mutation.key}, value $value');
        }
      }
      // Equal timestamps are legal; sequence deltas must still increase.
      final equal = Uint8List.fromList(original);
      ByteData.sublistView(equal)
          .setUint16(28 + 4 * width + 1, 20, Endian.little);
      expect(decode(equal)!.length, 3);
      for (final rows in [1, 8]) {
        expect(decode(sensorFrame(kind: kind, rows: rows))!.length, rows);
      }
    });
  }

  test(
      'AUX v3 retains flags, channel metadata and signed counts; inactive zero required',
      () {
    final frame = sensorFrame(kind: 3);
    final samples = AdcSample.decodeAll(frame)!;
    expect(samples.first.version, 3);
    expect(samples.first.activeChannelCount, 3);
    expect(samples.first.sampleValid, isTrue);
    expect(samples.first.measuredRateHz, 50);
    expect(samples.first.channels, [-200, -199, -198, 0, 0, 0, 0, 0]);
    expect(samples.map((s) => s.timestampMs), [0xfffffff0, 4, 24]);
    expect(() => samples.first.channels[0] = 1, throwsUnsupportedError);
    frame[28 + 4 * 20 + 10] = 1;
    expect(AdcSample.decodeAll(frame), isNull);
    expect(AdcSample.decode(frame), isNull);
  });

  test(
      'maximum deltas and nonzero Uint8List view offsets preserve exact wire values',
      () {
    final bytes =
        sensorFrame(rows: 2, sequence: 0xfffffffe, timestamp: 0xfffffff0);
    final data = ByteData.sublistView(bytes);
    data.setUint8(76, 255);
    data.setUint16(77, 65535, Endian.little);
    final padded = Uint8List(bytes.length + 11)
      ..setRange(7, 7 + bytes.length, bytes);
    final view = Uint8List.sublistView(padded, 7, 7 + bytes.length);
    final samples = RawImuSample.decodeAll(view)!;
    expect(samples.last.sequence, 253);
    expect(samples.last.timestampMs, 65519);
    expect(RawImuSample.decode(view)!.accelerometerX, -990);
    final status = statusFrame();
    final statusPadded = Uint8List(status.length + 9)
      ..setRange(5, 5 + status.length, status);
    expect(
        DeviceStatus.decode(
                Uint8List.sublistView(statusPadded, 5, 5 + status.length))!
            .lastError,
        -12345);
  });

  test(
      'a present zero raw measurement is retained, and a bad present peer rejects all rows',
      () {
    final zero = Uint8List(76)
      ..[0] = 3
      ..[1] = 1
      ..[2] = 1
      ..[3] = 1;
    final sample = RawImuSample.decodeAll(zero)!.single;
    expect(sample.accelerometerX, 0);
    expect(sample.flags.sampleValid, isFalse);
    final paired = sensorFrame(mask: 3)..[28 + 5 * 24 + 3] = 128;
    expect(RawImuSample.decodeAll(paired), isNull);
    expect(RawImuSample.decode(paired), isNull);
    final aux = sensorFrame(kind: 3, mask: 3)..[28 + 5 * 20 + 10] = 1;
    expect(AdcSample.decodeAll(aux), isNull);
    final quat = sensorFrame(kind: 2, mask: 3)..[28 + 5 * 22 + 3] = 32;
    expect(QuaternionSample.decodeAll(quat), isNull);
  });

  test('peer-only frames retain peer records without creating local samples',
      () {
    for (final kind in [1, 2, 3]) {
      final bytes = sensorFrame(kind: kind, mask: 2);
      if (kind == 1) {
        expect(RawImuSample.decodeAll(bytes)!.map((s) => s.gloveId), [1, 1, 1]);
        expect(RawImuSample.decode(bytes), isNull);
      } else if (kind == 2) {
        expect(QuaternionSample.decodeAll(bytes)!.map((s) => s.gloveId),
            [1, 1, 1]);
      } else {
        expect(AdcSample.decodeAll(bytes)!.map((s) => s.gloveId), [1, 1, 1]);
        expect(AdcSample.decode(bytes), isNull);
      }
    }
    expect(DeviceStatus.decodeAll(statusFrame(mask: 2))!.single.gloveId, 1);
    expect(DeviceStatus.decode(statusFrame(mask: 2)), isNull);
  });

  test('quaternion v3 uses signed Q30, accuracy and its own full flags', () {
    final s = QuaternionSample.decodeAll(sensorFrame(kind: 2))!.first;
    expect([s.q0Q30, s.q1Q30, s.q2Q30, s.q3Q30],
        [1073741824, -536870912, -2147483648, 2147483647]);
    expect([s.q0, s.q1, s.q2], [1, -0.5, -2]);
    expect(s.accuracy, 0xabcd);
    expect(s.version, 3);
    expect(s.measuredRateHz, 50);
    expect(
        s.sampleValid &&
            s.dmpActive &&
            s.synthetic &&
            s.fifoReset &&
            s.degraded,
        isTrue);
    expect(QuaternionSample.decodeAll(sensorFrame()), isNull);
    final samples = QuaternionSample.decodeAll(sensorFrame(kind: 2))!;
    expect(samples.map((s) => s.sequence), [0xfffffffe, 0xffffffff, 0]);
    expect(samples.map((s) => s.timestampMs), [0xfffffff0, 4, 24]);
  });

  test(
      'status v3 decodes every slot field, preserving independent drop counters',
      () {
    final s = DeviceStatus.decode(statusFrame())!;
    expect(s.version, 3);
    expect(s.gloveId, 0);
    expect(s.uptimeMs, 0xfedcba98);
    expect([s.requestedRate, s.actualSensorRate, s.notificationRate],
        [200, 199, 50]);
    expect([
      s.batteryMilliVolts,
      s.attMtu,
      s.boardId,
      s.imuState,
      s.batteryPercent
    ], [
      3712,
      247,
      1,
      3,
      87
    ]);
    expect(s.boardName, 'XIAO ESP32-C3');
    expect(s.firmwareVersion, '1.4.0');
    expect([s.deviceFlags, s.phy, s.featureFlags], [0xa5, 2, 3]);
    expect([
      s.freeHeap,
      s.droppedNotifications,
      s.fifoRecoveries,
      s.i2cErrors,
      s.bufferDroppedSamples,
      s.rawSamplesAcquired,
      s.lastError
    ], [
      123456,
      123,
      456,
      789,
      234,
      0xf1234567,
      -12345
    ]);
  });

  test('status v3 strict length, presence and whole peer validation', () {
    final original = statusFrame();
    for (var length = 0; length < original.length; length++) {
      expect(DeviceStatus.decodeAll(Uint8List.sublistView(original, 0, length)),
          isNull);
    }
    expect(
        DeviceStatus.decodeAll(Uint8List.fromList([...original, 0])), isNull);
    for (var o = 56; o < 108; o++) {
      expect(DeviceStatus.decodeAll(Uint8List.fromList(original)..[o] = 1),
          isNull);
    }
    for (final entry in {1: 1, 2: 0, 3: 2, 20: 101, 26: 0}.entries) {
      expect(
          DeviceStatus.decodeAll(
              Uint8List.fromList(original)..[entry.key] = entry.value),
          isNull);
    }
    final badPeer = statusFrame(mask: 3)..[56 + 22] = 0;
    expect(DeviceStatus.decodeAll(badPeer), isNull);
    expect(DeviceStatus.decode(badPeer), isNull);
  });

  test('legacy raw v1/v2 and status remain normalized singleton decoders', () {
    final v1 = ByteData(36)
      ..setUint8(0, 1)
      ..setUint8(1, 0x7f)
      ..setUint8(2, 3)
      ..setUint8(3, 2)
      ..setUint32(4, 0xffffffff, Endian.little)
      ..setUint32(8, 123456, Endian.little)
      ..setInt16(24, -32768, Endian.little);
    final raw = RawImuSample.decodeAll(v1.buffer.asUint8List())!.single;
    expect(raw.version, 1);
    expect(raw.gloveId, 0);
    expect(raw.sequence, 0xffffffff);
    expect(raw.timestampMs, 123456);
    expect(raw.magnetometerX, -32768);
    expect(raw.flags.magnetometerValid, isTrue);
    for (final entry in {1: 128, 2: 4, 3: 4, 34: 1}.entries) {
      expect(
          RawImuSample.decodeAll(Uint8List.fromList(v1.buffer.asUint8List())
            ..[entry.key] = entry.value),
          isNull);
    }
    final v2 = ByteData(20)
      ..setUint8(0, 2)
      ..setUint8(1, 0xff)
      ..setUint16(2, 65535, Endian.little)
      ..setUint32(4, 77, Endian.little)
      ..setInt16(18, -1234, Endian.little);
    final compact = RawImuSample.decodeAll(v2.buffer.asUint8List())!.single;
    expect(compact.version, 2);
    expect(compact.sequence, 65535);
    expect(compact.gyroscopeZ, -1234);
    expect(compact.magnetometerX, isNull);
    expect(compact.flags.magnetometerValid, isFalse);
    expect(compact.flags.temperatureValid, isFalse);
    expect(compact.flags.dmpActive, isTrue);
    final status1 = Uint8List(64)
      ..[0] = 1
      ..[1] = 2
      ..[60] = 1
      ..[61] = 3
      ..[62] = 9;
    final status2 = Uint8List(20)..[0] = 2;
    expect(DeviceStatus.decodeAll(status1)!.single.firmwareVersion, '1.3.9');
    expect(DeviceStatus.decodeAll(status1)!.single.boardName, 'XIAO ESP32-S3');
    expect(DeviceStatus.decodeAll(status2)!.single.version, 2);
    expect(DeviceStatus.decode(status1)!.featureFlags, 0);
    expect(DeviceStatus.decode(status2)!.bufferDroppedSamples, 0);
    expect(DeviceStatus.decode(Uint8List(0)), isNull);
    expect(RawImuSample.decode(Uint8List(0)), isNull);
    expect(RawImuSample.decode(Uint8List(20)..[0] = 9), isNull);
  });

  test('history provenance and sample-time fallback preserve legacy callers',
      () {
    final now = DateTime.utc(2026);
    final s = RawImuSample.decode(sensorFrame())!;
    final old = RawImuHistoryPoint(receivedAt: now, sample: s);
    expect(old.sampledAt, now);
    expect(old.sessionId, 0);
    expect(old.deviceId, isNull);
    final p = RawImuHistoryPoint(
        receivedAt: now,
        sample: s,
        sampleTime: now.subtract(const Duration(milliseconds: 40)),
        deviceId: 'local',
        sessionId: 7);
    expect(p.sampledAt.difference(p.receivedAt).inMilliseconds, -40);
    expect(p.deviceId, 'local');
    expect(p.sessionId, 7);
  });
}
