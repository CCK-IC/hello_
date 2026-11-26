import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ble_imu_visualizer/models/adc_history.dart';
import 'package:ble_imu_visualizer/models/ble_batch_assembler.dart';
import 'package:ble_imu_visualizer/models/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final fixture =
      jsonDecode(File('test/fixtures/batch_v3.json').readAsStringSync())
          as Map<String, dynamic>;
  for (final entry in fixture['cases'] as List<dynamic>) {
    final testCase = entry as Map<String, dynamic>;
    test('production C ${testCase['name']} decodes directly and at MTU 23', () {
      final frame = Uint8List.fromList((testCase['frame'] as List).cast<int>());
      final assembler =
          BleBatchAssembler(expectedKind: testCase['kind'] as int);
      Uint8List? reassembled;
      for (final fragment in testCase['fragmentsMtu23'] as List) {
        final result = assembler.add(
            Uint8List.fromList((fragment as List).cast<int>()),
            now: DateTime.utc(2026, 11, 16));
        expect(result.invalid, isFalse);
        if (result.frame != null) reassembled = result.frame;
      }
      expect(reassembled, orderedEquals(frame));
      for (final bytes in [frame, reassembled!]) {
        switch (testCase['kind']) {
          case 1:
            final samples = RawImuSample.decodeAll(bytes)!;
            final expected = testCase['samples'] as List;
            expect(samples.length, expected.length);
            for (var i = 0; i < samples.length; i++) {
              final s = samples[i];
              final e = expected[i] as Map;
              expect(s.gloveId, e['gloveId']);
              expect(s.sequence, e['sequence']);
              expect(s.timestampMs, e['timestampMs']);
              expect(s.flags.raw, e['flags']);
              expect(s.measuredRateHz, e['rateHz']);
              expect(s.accelerometerRangeCode, e['accelRange']);
              expect(s.gyroscopeRangeCode, e['gyroRange']);
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
                s.temperature,
              ], orderedEquals(e['values'] as List));
            }
          case 2:
            final samples = QuaternionSample.decodeAll(bytes)!;
            final expected = testCase['samples'] as List;
            expect(samples.length, expected.length);
            for (var i = 0; i < samples.length; i++) {
              final s = samples[i];
              final e = expected[i] as Map;
              expect(s.gloveId, e['gloveId']);
              expect(s.sequence, e['sequence']);
              expect(s.timestampMs, e['timestampMs']);
              expect(s.flags, e['flags']);
              expect(s.measuredRateHz, e['rateHz']);
              expect([s.q0Q30, s.q1Q30, s.q2Q30, s.q3Q30],
                  orderedEquals(e['q30'] as List));
              expect(s.accuracy, e['accuracy']);
            }
          case 3:
            final samples = AdcSample.decodeAll(bytes)!;
            final expected = testCase['samples'] as List;
            expect(samples.length, expected.length);
            for (var i = 0; i < samples.length; i++) {
              final s = samples[i];
              final e = expected[i] as Map;
              expect(s.gloveId, e['gloveId']);
              expect(s.sequence, e['sequence']);
              expect(s.timestampMs, e['timestampMs']);
              expect(s.flags, e['flags']);
              expect(s.measuredRateHz, e['rateHz']);
              expect(s.activeChannelCount, fixture['active_aux_channels']);
              expect(s.channels, orderedEquals(e['values'] as List));
            }
          case 4:
            final statuses = DeviceStatus.decodeAll(bytes)!;
            expect(statuses.length, 1);
            final s = statuses.single;
            final e = testCase['expected'] as Map;
            expect(s.gloveId, 0);
            expect(s.uptimeMs, e['uptimeMs']);
            expect(s.requestedRate, e['requestedRateHz']);
            expect(s.actualSensorRate, e['actualRateHz']);
            expect(s.notificationRate, e['notificationRateHz']);
            expect(s.adcNotificationRate, e['adcNotificationRateHz']);
            expect(s.batteryMilliVolts, e['batteryMv']);
            expect(s.attMtu, e['mtu']);
            expect(s.boardId, e['boardId']);
            expect(s.imuState, e['imuState']);
            expect(s.batteryPercent, e['batteryPercent']);
            expect(s.deviceFlags, e['flags']);
            expect(s.phy, e['phy']);
            expect(s.featureFlags, e['featureFlags']);
            expect(s.freeHeap, e['freeHeapBytes']);
            expect(s.droppedNotifications, e['droppedNotifications']);
            expect(s.fifoRecoveries, e['fifoOverflows']);
            expect(s.i2cErrors, e['i2cErrors']);
            expect(s.bufferDroppedSamples, e['droppedSensorSamples']);
            expect(s.rawSamplesAcquired, e['rawSampleCount']);
            expect(s.lastError, e['lastError']);
        }
      }
    });
  }
}
