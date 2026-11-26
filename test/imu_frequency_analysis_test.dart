import 'dart:math' as math;

import 'package:ble_imu_visualizer/models/imu_frequency_analysis.dart';
import 'package:ble_imu_visualizer/models/protocol.dart';
import 'package:ble_imu_visualizer/models/raw_imu_history.dart';
import 'package:flutter_test/flutter_test.dart';

RawImuHistoryPoint point(int ms, int sequence, double x, double y, double z,
    {bool valid = true,
    bool sampleValid = true,
    double gyroX = 0,
    bool gyroValid = false}) {
  int count(double value) => (value * 16384).round().clamp(-32768, 32767);
  return RawImuHistoryPoint(
    receivedAt: DateTime.utc(2026).add(Duration(milliseconds: ms)),
    sample: RawImuSample(
      version: 1,
      flags: RawImuFlags(
          (sampleValid ? 0x01 : 0) |
              (valid ? 0x02 : 0) |
              (gyroValid ? 0x04 : 0),
          1),
      accelerometerRangeCode: 0,
      gyroscopeRangeCode: 0,
      sequence: sequence,
      timestampMs: ms & 0xffffffff,
      accelerometerX: count(x),
      accelerometerY: count(y),
      accelerometerZ: count(z),
      gyroscopeX: (gyroX * 131).round().clamp(-32768, 32767),
      gyroscopeY: 0,
      gyroscopeZ: 0,
    ),
  );
}

List<RawImuHistoryPoint> signal(
        {int stepMs = 20, int offset = 0, bool jitter = false}) =>
    [
      for (var i = 0; i <= 400; i++)
        point(
          offset + i * stepMs + (jitter && i.isOdd ? 2 : 0),
          i,
          0.3 * math.sin(2 * math.pi * 2 * i * stepMs / 1000),
          0.2 * math.sin(2 * math.pi * 8 * i * stepMs / 1000),
          1,
        ),
    ];

List<RawImuHistoryPoint> impactsInMotion({
  int stepMs = 10,
  double? stopAfterSeconds,
  bool fasterImpacts = false,
}) {
  const cadence = 2.875;
  final points = <RawImuHistoryPoint>[];
  final noise =
      fasterImpacts ? 0.105 : (stopAfterSeconds == null ? 0.095 : 0.085);
  final impactHz = fasterImpacts ? 2 * cadence : cadence;
  for (var ms = 0; ms <= 8000; ms += stepMs) {
    final t = ms / 1000;
    // Off-cadence motion raises the lower-band noise floor. The stronger
    // 17 Hz motion represents fixture ringing on a perpendicular axis.
    final otherMotion =
        [9, 12, 15, 18, 26, 29, 32, 35, 38].fold(0.0, (sum, bin) {
      return sum + math.sin(2 * math.pi * bin * t / 8 + 0.13 * bin * bin);
    });
    final phase = (t * impactHz) % 1;
    final impact = stopAfterSeconds == null || t <= stopAfterSeconds
        ? 0.6 * math.exp(-phase / 0.1)
        : 0.0;
    final lateral =
        fasterImpacts ? 0.12 * math.sin(2 * math.pi * cadence * t) : 0.0;
    points.add(point(
      ms,
      ms ~/ stepMs,
      noise * otherMotion + 0.26 * math.sin(2 * math.pi * 17 * t) + lateral,
      0,
      1 + impact,
    ));
  }
  return points;
}

List<RawImuHistoryPoint> gappedSignal({
  int stepMs = 10,
  int gapMs = 40,
  int sequenceStep = 1,
  int suffixMs = 2400,
  double afterHz = 2,
  bool invalidBeforeGap = false,
}) {
  const firstAfterGap = 200;
  final points = <RawImuHistoryPoint>[];
  for (var i = 0; i <= firstAfterGap + suffixMs ~/ stepMs; i++) {
    final afterGap = i >= firstAfterGap;
    final ms = i * stepMs + (afterGap ? gapMs - stepMs : 0);
    final t = ms / 1000;
    final low = math.sin(2 * math.pi * (afterGap ? afterHz : 4) * t);
    points.add(point(
      ms,
      i + (afterGap ? sequenceStep - 1 : 0),
      0.3 * low,
      0.2 * math.sin(2 * math.pi * 8 * t),
      1,
      sampleValid: !invalidBeforeGap || i != firstAfterGap - 1,
      gyroX: 20 * low,
      gyroValid: true,
    ));
  }
  return points;
}

void main() {
  test('default search bands use the requested frequency ranges', () {
    final result = ImuFrequencyAnalyzer.analyze(signal());
    expect(result.bands.map((b) => [b.band.minHz, b.band.maxHz]), [
      [1, 5],
      [6.5, 10]
    ]);
  });

  test('separates spectral peaks using the sensor timestamp despite jitter',
      () {
    final result = ImuFrequencyAnalyzer.analyze(signal(jitter: true));
    expect(result.error, isNull);
    expect(result.sampleRateHz, closeTo(50, 0.1));
    expect(result.bands[0].peakHz, closeTo(2, 0.2));
    expect(result.bands[1].peakHz, closeTo(8, 0.2));
  });

  test('refuses a band beyond safe sampling bandwidth', () {
    final result = ImuFrequencyAnalyzer.analyze(signal(stepMs: 50));
    expect(result.error, isNull);
    expect(result.nyquistHz, closeTo(10, 0.1));
    expect(result.bands[1].peakHz, isNull);
    expect(result.bands[1].unavailableReason, contains('too low'));
  });

  test('accepts the vibration band at 25 Hz sampling', () {
    final result = ImuFrequencyAnalyzer.analyze(signal(stepMs: 40));
    expect(result.nyquistHz, closeTo(12.5, 0.1));
    expect(result.bands[1].peakHz, closeTo(8, 0.2));
  });

  test('rejects missing timing data rather than interpolating a large gap', () {
    final points = signal();
    points.removeRange(250, 255);
    final result = ImuFrequencyAnalyzer.analyze(points);
    expect(result.error, contains('gap'));
    expect(result.bands.every((b) => b.peakHz == null), isTrue);
  });

  test('recovers only percussion once two seconds of fresh samples arrive', () {
    final tooSoon = ImuFrequencyAnalyzer.analyze(gappedSignal(suffixMs: 1990));
    expect(tooSoon.error, contains('gap'));
    expect(tooSoon.bands.every((band) => band.peakHz == null), isTrue);

    final result = ImuFrequencyAnalyzer.analyze(gappedSignal(suffixMs: 2000));
    expect(result.error, isNull);
    expect(result.duration, const Duration(seconds: 2));
    expect(result.sampleCount, 201);
    expect(result.sampleRateHz, closeTo(100, 0.1));
    expect(result.bands[0].peakHz, closeTo(2, 0.05));
    expect(result.bands[1].peakHz, isNull);
    expect(result.bands[1].unavailableReason, contains('gap'));
  });

  test('recovers angular-velocity percussion after a 45 Hz packet gap', () {
    final points = gappedSignal(stepMs: 22, gapMs: 66, sequenceStep: 3);
    final band = [ImuFrequencyAnalyzer.defaultBands.first];
    final result = ImuFrequencyAnalyzer.analyze(points,
        bands: band, percussionBandIndex: 0, sensor: RawSensorType.gyroscope);
    expect(result.error, isNull);
    expect(result.sampleRateHz, closeTo(45.45, 0.1));
    expect(result.bands.single.peakHz, closeTo(2, 0.05));
    expect(
        ImuFrequencyAnalyzer.analyze(points,
                bands: band, sensor: RawSensorType.gyroscope)
            .error,
        contains('gap'));
  });

  test('resolves a short-suffix peak near the band edge', () {
    final result = ImuFrequencyAnalyzer.analyze(
        gappedSignal(suffixMs: 2020, afterHz: 1.05));
    expect(result.bands.first.peakHz, closeTo(1.05, 0.05));
    expect(
        ImuFrequencyAnalyzer.analyze(
                gappedSignal(suffixMs: 2020, afterHz: 0.85))
            .bands
            .first
            .peakHz,
        isNull);
  });

  test('keeps long gaps, inconsistent sequences and invalid windows rejected',
      () {
    for (final points in [
      gappedSignal(gapMs: 60),
      gappedSignal(sequenceStep: -1),
      gappedSignal(sequenceStep: 12),
      gappedSignal(gapMs: 29, sequenceStep: 4),
    ]) {
      final result = ImuFrequencyAnalyzer.analyze(points);
      expect(result.error, contains('gap'));
      expect(result.bands.every((band) => band.peakHz == null), isTrue);
    }
    final result =
        ImuFrequencyAnalyzer.analyze(gappedSignal(invalidBeforeGap: true));
    expect(result.error, contains('invalid'));
    expect(result.bands.every((band) => band.peakHz == null), isTrue);
  });

  test('a small allowed gap does not inflate the measured sample rate', () {
    final points = signal();
    points.removeAt(250);
    final result = ImuFrequencyAnalyzer.analyze(points);
    expect(result.error, isNull);
    expect(result.sampleRateHz!, lessThan(50));
    expect(result.bands[0].peakHz, closeTo(2, 0.2));
  });

  test('rejects invalid accelerometer samples', () {
    final points = signal();
    points[300] = point(6000, 300, 0, 0, 1, valid: false);
    expect(ImuFrequencyAnalyzer.analyze(points).error, contains('invalid'));
    points[300] = point(6000, 300, 0, 0, 1, sampleValid: false);
    expect(ImuFrequencyAnalyzer.analyze(points).error, contains('invalid'));
  });

  test('does not invent a high-band peak from leakage of a 2 Hz motion', () {
    final points = [
      for (var i = 0; i <= 400; i++)
        point(i * 20, i, 0.4 * math.sin(2 * math.pi * 2 * i * 0.02), 0, 1),
    ];
    final result = ImuFrequencyAnalyzer.analyze(points);
    expect(result.bands[0].peakHz, closeTo(2, 0.2));
    expect(result.bands[1].peakHz, isNull);
    expect(result.bands[1].unavailableReason, contains('weak'));
  });

  test('does not report a distinct peak for flat broadband spectral noise', () {
    final random = math.Random(24);
    final points = [
      for (var i = 0; i <= 400; i++)
        point(i * 20, i, (random.nextDouble() - 0.5) * 0.2,
            (random.nextDouble() - 0.5) * 0.2, 1),
    ];
    final result = ImuFrequencyAnalyzer.analyze(points);
    expect(result.bands.every((band) => band.peakHz == null), isTrue);
  });

  test('acceleration recurrence recovers a marginal impact peak', () {
    final band = [ImuFrequencyAnalyzer.defaultBands.first];
    for (final stepMs in [10, 22]) {
      final points = impactsInMotion(stepMs: stepMs);
      expect(
          ImuFrequencyAnalyzer.analyze(points, bands: band).bands.single.peakHz,
          isNull);
      expect(ImuFrequencyAnalyzer.analyze(points).bands.first.peakHz,
          closeTo(2.875, 0.125));
      final explicit = ImuFrequencyAnalyzer.analyze(points,
          bands: band, percussionBandIndex: 0);
      expect(explicit.bands.single.peakHz, closeTo(2.875, 0.125));
    }
  });

  test('an earlier cadence or a multiple of a faster period cannot corroborate',
      () {
    final band = [ImuFrequencyAnalyzer.defaultBands.first];
    for (final points in [
      impactsInMotion(stopAfterSeconds: 5.8),
      impactsInMotion(fasterImpacts: true),
    ]) {
      final spectral = ImuFrequencyAnalyzer.analyze(points, bands: band);
      expect(spectral.bands.single.peakHz, isNull);
      expect(ImuFrequencyAnalyzer.analyze(points).bands.first.peakHz, isNull);
    }
  });

  test('does not corroborate from a previous device timestamp epoch', () {
    final points = impactsInMotion()..addAll(signal().take(80));
    final result = ImuFrequencyAnalyzer.analyze(points);
    expect(result.bands.first.peakHz, isNull);
  });

  test('analyzes gyroscope axes and validates the selected sensor', () {
    final points = [
      for (var i = 0; i <= 400; i++)
        point(i * 20, i, 0, 0, 1,
            gyroX: 20 * math.sin(2 * math.pi * 3 * i * 0.02), gyroValid: true),
    ];
    final result =
        ImuFrequencyAnalyzer.analyze(points, sensor: RawSensorType.gyroscope);
    expect(result.error, isNull);
    expect(result.bands[0].peakHz, closeTo(3, 0.2));
    expect(ImuFrequencyAnalyzer.analyze(points).bands[0].peakHz, isNull);
    points[100] = point(2000, 100, 0, 0, 1);
    expect(
        ImuFrequencyAnalyzer.analyze(points, sensor: RawSensorType.gyroscope)
            .error,
        contains('invalid gyroscope'));
  });

  test('handles unsigned device timestamp rollover', () {
    final result = ImuFrequencyAnalyzer.analyze(signal(offset: 0xfffff000));
    expect(result.error, isNull);
    expect(result.bands[0].peakHz, closeTo(2, 0.2));
  });

  test('reports no varying signal and waits for enough data', () {
    final stationary = [
      for (var i = 0; i <= 400; i++) point(i * 20, i, 0, 0, 1)
    ];
    final result = ImuFrequencyAnalyzer.analyze(stationary);
    expect(result.bands[0].peakHz, isNull);
    expect(result.bands[0].unavailableReason, contains('No varying'));
    expect(ImuFrequencyAnalyzer.analyze(stationary.take(2).toList()).error,
        isNotNull);
  });
}
