import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ble_imu_visualizer/models/adc_frequency_analysis.dart';
import 'package:ble_imu_visualizer/models/adc_history.dart';
import 'package:ble_imu_visualizer/models/imu_frequency_analysis.dart';
import 'package:ble_imu_visualizer/models/protocol.dart';
import 'package:ble_imu_visualizer/models/raw_imu_history.dart';
import 'package:flutter_test/flutter_test.dart';

import 'batch_test_fixtures.dart';

const _bands = [
  FrequencyBand('Percussion', 1, 5),
  FrequencyBand('Vibration', 6.5, 10),
];
const _windowMs = 10000;
final _wallTime = DateTime.utc(2026);

double _wave(int ms, double hz) => math.sin(2 * math.pi * hz * ms / 1000);

double _impact(int ms, {int periodMs = 500, int phaseMs = 250}) {
  final offset = (ms - phaseMs + periodMs ~/ 2) % periodMs - periodMs ~/ 2;
  return math.exp(-0.5 * math.pow(offset / 25, 2));
}

int _tap(int ms) => 400 + (800 * _impact(ms)).round();

AdcHistoryPoint _adcPoint(int time, int index, int value,
    {int channel = 0, int active = 3, bool valid = true, bool legacy = false}) {
  final rawTime = time & 0xffffffff;
  final bytes = legacy
      ? Uint8List(22)
      : sensorFrame(kind: 3, rows: 1, timestamp: rawTime, sequence: index);
  final data = ByteData.sublistView(bytes);
  if (legacy) {
    data
      ..setUint8(0, 1)
      ..setUint8(1, index & 0xff)
      ..setUint32(2, rawTime, Endian.little)
      ..setInt16(6 + channel * 2, value, Endian.little);
  } else {
    data
      ..setUint16(12, 100, Endian.little)
      ..setUint8(14, active)
      ..setUint8(31, valid ? 1 : 0)
      ..setInt16(32 + channel * 2, value, Endian.little);
  }
  // Give each stream unrelated wall-clock and sample-time mappings.
  return AdcHistoryPoint(_wallTime, AdcSample.decode(bytes)!,
      sampleTime: _wallTime.subtract(const Duration(hours: 1)));
}

List<AdcHistoryPoint> _adc(
  int Function(int ms) value, {
  int clockBase = 100000,
  int startMs = 0,
  int endMs = _windowMs,
  int channel = 0,
  bool legacy = false,
}) =>
    [
      for (var i = 0; startMs + i * 10 <= endMs; i++)
        _adcPoint(clockBase + startMs + i * 10, i, value(startMs + i * 10),
            channel: channel, legacy: legacy),
    ];

RawImuHistoryPoint _imuPoint(int time, int index, double x,
        {double z = 1, double gyroX = 0, int flags = 7}) =>
    RawImuHistoryPoint(
      receivedAt: _wallTime.add(const Duration(days: 1)),
      sampleTime: _wallTime.add(const Duration(hours: 1)),
      sample: RawImuSample(
        version: 1,
        flags: RawImuFlags(flags, 1),
        accelerometerRangeCode: 0,
        gyroscopeRangeCode: 0,
        sequence: index,
        timestampMs: time & 0xffffffff,
        accelerometerX: (16384 * x).round(),
        accelerometerY: 0,
        accelerometerZ: (16384 * z).round(),
        gyroscopeX: (131 * gyroX).round(),
        gyroscopeY: 0,
        gyroscopeZ: 0,
      ),
    );

List<RawImuHistoryPoint> _imu(
  double Function(int ms) x, {
  int clockBase = 100000,
  int startMs = 7,
  int endMs = _windowMs,
  double Function(int)? z,
  double Function(int)? gyroX,
}) {
  final points = <RawImuHistoryPoint>[];
  for (var i = 0;; i++) {
    final ms = startMs + (i * 1000 / 45).round() + (i.isOdd ? 1 : 0);
    if (ms > endMs) return points;
    points.add(_imuPoint(clockBase + ms, i, x(ms),
        z: z?.call(ms) ?? 1, gyroX: gyroX?.call(ms) ?? 0));
  }
}

({ImuFrequencyAnalysis adc, ImuFrequencyAnalysis fused}) _analyze(
    List<AdcHistoryPoint> adc, List<RawImuHistoryPoint> imu,
    {int channel = 0,
    RawSensorType sensor = RawSensorType.accelerometer,
    int? highThreshold}) {
  final result = AdcFrequencyAnalyzer.analyze(
    adc,
    imu,
    bands: _bands,
    sensor: sensor,
    channel: channel,
    highThreshold: highThreshold,
  );
  expect(result.adc.bands.map((b) => b.band), [_bands[0]]);
  expect(result.fused.bands.map((b) => b.band), _bands);
  return result;
}

bool _grip(int ms) => ms >= 3100 && ms < 6700;

void main() {
  test('matches periodic ADC and signed IMU impacts at independent rates', () {
    final adc = _adc(_tap, channel: 2);
    final imu = _imu((_) => 0, startMs: 317, z: (ms) => 1 - 0.4 * _impact(ms));
    final result = _analyze(adc, imu, channel: 2);
    expect(result.adc.error, isNull);
    expect(result.adc.sampleRateHz, closeTo(100, 0.01));
    expect(result.adc.bands.single.peakHz, closeTo(2, 0.03));
    expect(result.fused.error, isNull);
    expect(result.fused.sampleRateHz, closeTo(45, 0.1));
    expect(result.fused.nyquistHz, closeTo(22.5, 0.05));
    expect(result.fused.duration, lessThan(result.adc.duration));
    expect(result.fused.bands[0].peakHz, closeTo(2, 0.03));
    expect(result.fused.bands[1].peakHz, isNull);
  });

  test('handles narrow ADC taps and the selected IMU sensor', () {
    final adc = _adc((ms) => ms % 1000 == 250 ? 600 : 0, legacy: true);
    final imu = _imu((_) => 0, gyroX: (ms) => 20 * _impact(ms, periodMs: 1000));
    final result = _analyze(adc, imu, sensor: RawSensorType.gyroscope);
    expect(result.adc.bands.single.peakHz, closeTo(1, 0.01));
    expect(result.fused.bands[0].peakHz, closeTo(1, 0.01));
    expect(_analyze(adc, imu).fused.bands[0].peakHz, isNull);
  });

  test('same cadence with displaced peaks does not corroborate percussion', () {
    final result = _analyze(
      _adc(_tap),
      _imu((ms) => 0.4 * _impact(ms, phaseMs: 375)),
    );
    expect(result.adc.bands.single.peakHz, closeTo(2, 0.03));
    expect(result.fused.bands[0].peakHz, isNull);
    expect(result.fused.bands[0].unavailableReason, contains('synchronized'));
  });

  test('rejects extra IMU impacts at a harmonic of the ADC cadence', () {
    final result = _analyze(
      _adc(_tap),
      _imu((ms) => 0.4 * _impact(ms, periodMs: 250)),
    );
    expect(result.adc.bands.single.peakHz, closeTo(2, 0.03));
    expect(result.fused.bands[0].peakHz, isNull);
  });

  test('flat, drifting, and noise-only ADC cannot establish percussion', () {
    final imu = _imu((ms) => 0.4 * _impact(ms));
    final random = math.Random(28);
    for (final signal in <int Function(int)>[
      (_) => 2200,
      (ms) => 300 + ms ~/ 10,
      (_) => random.nextInt(600),
    ]) {
      final result = _analyze(_adc(signal), imu);
      expect(result.adc.bands.single.peakHz, isNull);
      expect(result.fused.bands[0].peakHz, isNull);
    }
  });

  test('varied tap spacing and a pause still give typical ADC cadence', () {
    const taps = {240, 830, 1780, 2010, 3150, 4100};
    final result = _analyze(_adc((ms) => taps.contains(ms) ? 700 : 100), []);
    // The 1.14-second pause exceeds the configured band. The remaining
    // periods are .23, .59, .95 and .95 seconds, with a median of .77.
    expect(result.adc.bands.single.peakHz, closeTo(1 / 0.77, 0.001));
  });

  test('fuses uneven taps with delayed impacts in different directions', () {
    const taps = [500, 870, 1600, 2100, 2880, 3160, 3980, 4600, 5070, 5700];
    double pulse(int ms, int tap) =>
        0.35 * math.exp(-0.5 * math.pow((ms - tap - 55) / 20, 2));
    final adc = _adc((ms) => 140 + (taps.contains(ms) ? 300 + ms ~/ 12 : 0));
    final imu = _imu(
      (ms) => [for (var i = 0; i < taps.length; i += 3) pulse(ms, taps[i])]
          .reduce(math.max),
      z: (ms) =>
          1 +
          [for (var i = 1; i < taps.length; i += 3) pulse(ms, taps[i])]
              .reduce(math.max) -
          [for (var i = 2; i < taps.length; i += 3) pulse(ms, taps[i])]
              .reduce(math.max),
    );
    final result = _analyze(adc, imu);
    expect(result.adc.bands.single.peakHz, closeTo(1000 / 620, 0.01));
    expect(result.fused.bands[0].peakHz, closeTo(1000 / 620, 0.01));
  });

  test('vibration uses IMU motion inside a sustained ADC-high interval', () {
    final result = _analyze(
      _adc((ms) => _grip(ms) ? 1300 : 200),
      _imu((ms) => _grip(ms) ? 0.25 * _wave(ms, 8) : 0.6 * _wave(ms, 9.5)),
    );
    expect(result.adc.bands.single.peakHz, isNull);
    expect(result.fused.bands[0].peakHz, isNull);
    expect(result.fused.bands[1].peakHz, closeTo(8, 0.18));
  });

  test('vibration ignores IMU motion outside the high interval', () {
    final result = _analyze(
      _adc((ms) => _grip(ms) ? 1300 : 200),
      _imu((ms) => _grip(ms) ? 0 : 0.5 * _wave(ms, 8)),
    );
    expect(result.fused.bands[1].peakHz, isNull);
    expect(result.fused.bands[1].unavailableReason, contains('No varying'));
  });

  test('vibration requires ADC contrast and does not join short highs', () {
    final imu = _imu((ms) => 0.4 * _wave(ms, 8));
    final flat = _analyze(_adc((_) => 2000), imu);
    expect(flat.fused.bands[1].peakHz, isNull);
    expect(flat.fused.bands[1].unavailableReason, contains('contrast'));
    final intermittent =
        _analyze(_adc((ms) => ms % 1000 < 700 ? 1300 : 200), imu);
    expect(intermittent.fused.bands[1].peakHz, isNull);
    expect(
        intermittent.fused.bands[1].unavailableReason, contains('sustained'));
  });

  test('manual vibration threshold works with ADC already high', () {
    final adc = _adc((_) => 2000);
    final imu = _imu((ms) => 0.4 * _wave(ms, 8));
    final high = _analyze(adc, imu, highThreshold: 1500);
    expect(high.fused.bands[1].peakHz, closeTo(8, 0.18));
    final low = _analyze(adc, imu, highThreshold: 2500);
    expect(low.fused.bands[1].peakHz, isNull);
  });

  test('absent and nonoverlapping streams only disable affected estimates', () {
    final adc = _adc(_tap);
    final imu = _imu((ms) => 0.4 * _impact(ms));
    expect(_analyze([], imu).adc.error, contains('Waiting'));
    final adcOnly = _analyze(adc, []);
    expect(adcOnly.adc.bands.single.peakHz, closeTo(2, 0.03));
    expect(adcOnly.fused.error, contains('both'));
    final disjoint =
        _analyze(adc, _imu((ms) => 0.4 * _impact(ms), clockBase: 120000));
    expect(disjoint.fused.error, contains('overlap'));
    final unequal = _analyze(adc, _imu((ms) => 0.4 * _impact(ms), endMs: 9300));
    expect(unequal.fused.bands[0].peakHz, closeTo(2, 0.03));
    final stale = _analyze(adc, _imu((ms) => 0.4 * _impact(ms), endMs: 8000));
    expect(stale.fused.error, contains('stale'));
    expect(stale.adc.bands.single.peakHz, closeTo(2, 0.03));
  });

  test('skips isolated invalid samples and rejects inactive channels', () {
    final adc = _adc(_tap);
    final imu = _imu((ms) => 0.4 * _impact(ms));
    final inactive = _analyze(adc, imu, channel: 3);
    expect(inactive.adc.error, contains('inactive'));
    expect(inactive.fused.error, contains('inactive'));
    expect(_analyze(adc, imu, channel: -1).adc.error, contains('out of range'));

    final withInvalidAdc = [...adc];
    withInvalidAdc[300] = _adcPoint(103000, 300, 400, valid: false);
    final invalidAdc = _analyze(withInvalidAdc, imu);
    expect(invalidAdc.adc.bands.single.peakHz, closeTo(2, 0.03));
    expect(invalidAdc.fused.bands[0].peakHz, closeTo(2, 0.03));

    for (final flags in [2, 1]) {
      final withInvalidImu = [...imu];
      withInvalidImu[100] =
          _imuPoint(imu[100].sample.timestampMs, 100, 0, flags: flags);
      final invalidImu = _analyze(adc, withInvalidImu);
      expect(invalidImu.adc.bands.single.peakHz, closeTo(2, 0.03));
      expect(invalidImu.fused.bands[0].peakHz, closeTo(2, 0.03));
    }
  });

  test('isolated dropped samples preserve estimates', () {
    final adc = _adc(_tap);
    final imu = _imu((ms) => 0.4 * _impact(ms));
    final droppedAdc = _analyze(adc..removeAt(300), imu);
    expect(droppedAdc.adc.bands.single.peakHz, closeTo(2, 0.03));
    expect(droppedAdc.fused.bands[0].peakHz, closeTo(2, 0.03));
    final droppedImu = _analyze(_adc(_tap), imu..removeAt(100));
    expect(droppedImu.adc.bands.single.peakHz, closeTo(2, 0.03));
    expect(droppedImu.fused.bands[0].peakHz, closeTo(2, 0.03));
  });

  test('uses only new evidence after a long capture gap', () {
    final adc = _adc(_tap)..removeRange(200, 900);
    final result = _analyze(adc, _imu((ms) => 0.4 * _impact(ms)));
    expect(result.adc.duration, const Duration(seconds: 1));
    expect(result.adc.bands.single.peakHz, isNull);
    expect(result.fused.bands[0].peakHz, isNull);
  });

  test('aligns across unsigned rollover even when latest samples straddle it',
      () {
    const base = 0xffffffff - 9900;
    final adc = _adc(_tap, clockBase: base);
    final imu = _imu((ms) => 0.4 * _impact(ms), clockBase: base, endMs: 9850);
    expect(adc.last.sample.timestampMs, lessThan(1000));
    expect(imu.last.sample.timestampMs, greaterThan(0xffff0000));
    final result = _analyze(adc, imu);
    expect(result.adc.bands.single.peakHz, closeTo(2, 0.03));
    expect(result.fused.bands[0].peakHz, closeTo(2, 0.03));
  });

  test('gates a sustained high interval that crosses device rollover', () {
    const base = 0xffffffff - 5000;
    final result = _analyze(
      _adc((ms) => _grip(ms) ? 1300 : 200, clockBase: base),
      _imu((ms) => _grip(ms) ? 0.4 * _wave(ms, 8) : 0, clockBase: base),
    );
    expect(result.fused.bands[1].peakHz, closeTo(8, 0.18));
  });
}
