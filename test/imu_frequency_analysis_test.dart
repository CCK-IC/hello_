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

void main() {
  test('separates spectral peaks using the sensor timestamp despite jitter',
      () {
    final result = ImuFrequencyAnalyzer.analyze(signal(jitter: true));
    expect(result.error, isNull);
    expect(result.sampleRateHz, closeTo(50, 0.1));
    expect(result.bands[0].peakHz, closeTo(2, 0.2));
    expect(result.bands[1].peakHz, closeTo(8, 0.2));
  });

  test('refuses a band beyond safe sampling bandwidth', () {
    final result = ImuFrequencyAnalyzer.analyze(signal(stepMs: 40));
    expect(result.error, isNull);
    expect(result.nyquistHz, closeTo(12.5, 0.1));
    expect(result.bands[1].peakHz, isNull);
    expect(result.bands[1].unavailableReason, contains('too low'));
  });

  test('rejects missing timing data rather than interpolating a large gap', () {
    final points = signal();
    points.removeRange(250, 255);
    final result = ImuFrequencyAnalyzer.analyze(points);
    expect(result.error, contains('gap'));
    expect(result.bands.every((b) => b.peakHz == null), isTrue);
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
