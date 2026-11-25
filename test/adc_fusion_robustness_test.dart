import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ble_imu_visualizer/models/adc_frequency_analysis.dart';
import 'package:ble_imu_visualizer/models/adc_history.dart';
import 'package:ble_imu_visualizer/models/imu_frequency_analysis.dart';
import 'package:ble_imu_visualizer/models/protocol.dart';
import 'package:ble_imu_visualizer/models/raw_imu_history.dart';
import 'package:flutter_test/flutter_test.dart';

const _bands = [
  FrequencyBand('Percussion', 1, 5),
  FrequencyBand('Vibration', 6.5, 10),
];
final _receivedAt = DateTime.utc(2026);

AdcHistoryPoint _adcPoint(int ms, int counts) {
  final data = ByteData(22)
    ..setUint8(0, 1)
    ..setUint8(1, (ms ~/ 10) & 0xff)
    ..setUint32(2, ms, Endian.little)
    ..setInt16(6, counts, Endian.little);
  return AdcHistoryPoint(
      _receivedAt, AdcSample.decode(data.buffer.asUint8List())!);
}

RawImuHistoryPoint _imuPoint(int ms, double x) => RawImuHistoryPoint(
      receivedAt: _receivedAt,
      sample: RawImuSample(
        version: 1,
        flags: const RawImuFlags(7, 1),
        accelerometerRangeCode: 0,
        gyroscopeRangeCode: 0,
        sequence: ms ~/ 20,
        timestampMs: ms,
        accelerometerX: (16384 * x).round(),
        accelerometerY: 0,
        accelerometerZ: 16384,
        gyroscopeX: 0,
        gyroscopeY: 0,
        gyroscopeZ: 0,
      ),
    );

({ImuFrequencyAnalysis adc, ImuFrequencyAnalysis fused}) _analyze(
  int Function(int) adc,
  double Function(int) imu, {
  int endMs = 5000,
  int? highThreshold,
}) =>
    AdcFrequencyAnalyzer.analyze(
      [for (var ms = 0; ms <= endMs; ms += 10) _adcPoint(ms, adc(ms))],
      [for (var ms = 0; ms <= endMs; ms += 20) _imuPoint(ms, imu(ms))],
      bands: _bands,
      sensor: RawSensorType.accelerometer,
      highThreshold: highThreshold,
    );

int _tapCounts(int ms, List<int> taps) =>
    taps.any((tap) => (ms - tap).abs() <= 10) ? 900 : 200;

double _impacts(int ms, List<int> times) {
  final distance = times.map((time) => (ms - time).abs()).reduce(math.min);
  return 0.4 * math.exp(-0.5 * math.pow(distance / 18, 2));
}

double _wave(int ms) => 0.4 * math.sin(2 * math.pi * 8 * ms / 1000);

void main() {
  test('noisy ADC contacts yield one tap each despite a brief dip', () {
    const taps = [400, 800, 1200, 1600, 2000, 2400];
    int noise(int ms) => (ms ~/ 10 * 17) % 43;
    final result = _analyze(
      (ms) {
        for (final tap in taps) {
          final offset = ms - tap;
          if (offset >= -30 && offset <= 70 && offset != 10) {
            return noise(ms) + (offset == 0 ? 270 : 160);
          }
        }
        return noise(ms);
      },
      (ms) => _impacts(ms, [for (final tap in taps) tap - 25]),
      endMs: 3000,
    );
    expect(result.adc.bands.first.peakHz, closeTo(2.5, 0.12));
    expect(result.fused.bands.first.peakHz, closeTo(2.5, 0.12));

    final hold = _analyze(
      (ms) => (ms >= 500 && ms <= 2600 ? 225 : 0) + noise(ms),
      (ms) => ms >= 500 && ms <= 2600 ? _wave(ms) : 0,
      endMs: 3200,
    );
    expect(hold.adc.bands.first.peakHz, isNull);
    expect(hold.fused.bands.first.peakHz, isNull);
    expect(hold.fused.bands.last.peakHz, closeTo(8, 0.25));
  });

  for (final periodMs in [300, 600]) {
    test('recomputes matched cadence with ADC rebounds at ${periodMs}ms', () {
      final taps = [for (var i = 0; i < 8; i++) 420 + i * periodMs];
      final adcPeaks = [
        ...taps,
        for (final tap in taps.take(4)) tap + periodMs ~/ 2,
      ];
      final impacts = [for (final tap in taps) tap + 60];
      final result = _analyze(
        (ms) => _tapCounts(ms, adcPeaks),
        (ms) => _impacts(ms, impacts),
      );
      expect(result.adc.bands.single.peakHz,
          periodMs == 300 ? isNull : closeTo(1000 / 300, 0.01));
      expect(result.fused.bands.first.peakHz, closeTo(1000 / periodMs, 0.01));
    });
  }

  for (final lagMs in [-75, 75]) {
    test('matches a stable ${lagMs}ms offset with missed and extra impacts',
        () {
      final taps = [for (var i = 0; i < 9; i++) 500 + i * 500];
      final impacts = [
        for (var i = 0; i < taps.length; i++)
          if (i % 3 != 2) taps[i] + lagMs + (i.isEven ? 5 : -5),
        1750,
      ];
      final result = _analyze(
        (ms) => _tapCounts(ms, taps),
        (ms) => _impacts(ms, impacts),
      );
      expect(result.fused.bands.first.peakHz, closeTo(2, 0.01));
    });
  }

  test('rejects impacts that do not have a stable offset', () {
    final taps = [for (var i = 0; i < 9; i++) 500 + i * 500];
    const offsets = [-70, 0, 70];
    final impacts = [
      for (var i = 0; i < taps.length; i++) taps[i] + offsets[i % 3],
    ];
    final result = _analyze(
      (ms) => _tapCounts(ms, taps),
      (ms) => _impacts(ms, impacts),
    );
    expect(result.fused.bands.first.peakHz, isNull);
    expect(
        result.fused.bands.first.unavailableReason, contains('synchronized'));
  });

  test('explains synchronized taps without enough in-band intervals', () {
    final taps = [for (var i = 0; i < 7; i++) 500 + i * 120];
    final impacts = [for (final tap in taps) tap + 40];
    final result = _analyze(
      (ms) => _tapCounts(ms, taps),
      (ms) => _impacts(ms, impacts),
      endMs: 2000,
    );
    expect(result.fused.bands.first.peakHz, isNull);
    expect(result.fused.bands.first.unavailableReason,
        contains('synchronized tap intervals'));
  });

  test('uses a 5% low reference and keeps a settled grip gated', () {
    final result = _analyze(
      (ms) => switch (ms) {
        < 500 => 200,
        < 1750 => 1200,
        _ => 720,
      },
      (ms) => ms >= 1750 ? _wave(ms) : 0,
      endMs: 10000,
    );
    expect(result.fused.bands.last.peakHz, closeTo(8, 0.1));
  });

  test('bridges an 80ms dip in a short high long enough for the spectrum', () {
    final result = _analyze(
      (ms) => ms >= 600 && ms <= 2600 && (ms < 1550 || ms >= 1630) ? 900 : 200,
      (ms) => ms >= 600 && ms <= 2600 ? _wave(ms) : 0,
      endMs: 3200,
    );
    final vibration = result.fused.bands.last;
    expect(vibration.peakHz, closeTo(8, 0.2),
        reason: vibration.unavailableReason);
  });

  test('sustained high excludes separate bursts and low-dominated chatter', () {
    for (final highMs in [30, 700]) {
      final periodMs = highMs == 30 ? 100 : 800;
      final result = _analyze(
        (ms) => ms % periodMs < highMs ? 900 : 200,
        _wave,
      );
      expect(result.fused.bands.last.peakHz, isNull);
      expect(result.fused.bands.last.unavailableReason, contains('sustained'));
    }
  });

  test('manual floor gates vibration on constant ADC counts', () {
    const counts = 1200;
    expect(_analyze((_) => counts, _wave).fused.bands.last.unavailableReason,
        contains('contrast'));
    expect(
      _analyze((_) => counts, _wave, highThreshold: counts)
          .fused
          .bands
          .last
          .peakHz,
      closeTo(8, 0.1),
    );
    expect(
      _analyze((_) => counts, _wave, highThreshold: counts + 1)
          .fused
          .bands
          .last
          .peakHz,
      isNull,
    );
  });
}
