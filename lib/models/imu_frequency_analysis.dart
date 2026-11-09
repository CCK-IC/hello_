import 'dart:math' as math;

import 'raw_imu_history.dart';

/// A descriptive frequency search range, not a clinical classification.
class FrequencyBand {
  final String label;
  final double minHz;
  final double maxHz;

  const FrequencyBand(this.label, this.minHz, this.maxHz)
      : assert(minHz > 0 && maxHz > minHz);
}

class FrequencyBandResult {
  final FrequencyBand band;
  final double? peakHz;
  final String? unavailableReason;

  const FrequencyBandResult(this.band, this.peakHz, this.unavailableReason);
}

class ImuFrequencyAnalysis {
  final String? error;
  final double? sampleRateHz;
  final double? nyquistHz;
  final Duration duration;
  final int sampleCount;
  final List<FrequencyBandResult> bands;

  const ImuFrequencyAnalysis({
    required this.error,
    required this.sampleRateHz,
    required this.nyquistHz,
    required this.duration,
    required this.sampleCount,
    required this.bands,
  });
}

/// Estimates peaks from a contiguous recent window of IMU vectors.
///
/// Uses device timestamps (including 32-bit wrap), rather than BLE arrival
/// times, to estimate the sample rate and linearly resample small timing
/// jitter. Large gaps are rejected instead of filling in missing movement.
/// The combined X/Y/Z spectral power is orientation-independent under a fixed
/// rotation; it is not a diagnosis or a count of therapeutic actions.
class ImuFrequencyAnalyzer {
  static const defaultBands = <FrequencyBand>[
    FrequencyBand('Lower band', 1, 5),
    FrequencyBand('Higher band', 6.5, 10),
  ];

  static ImuFrequencyAnalysis analyze(
    List<RawImuHistoryPoint> points, {
    Duration window = const Duration(seconds: 4),
    List<FrequencyBand> bands = defaultBands,
    RawSensorType sensor = RawSensorType.accelerometer,
  }) {
    final sensorName = sensor == RawSensorType.gyroscope
        ? 'gyroscope'
        : sensor == RawSensorType.magnetometer
            ? 'magnetometer'
            : 'accelerometer';
    ImuFrequencyAnalysis unavailable(String reason,
            {double? rate, Duration duration = Duration.zero, int count = 0}) =>
        ImuFrequencyAnalysis(
          error: reason,
          sampleRateHz: rate,
          nyquistHz: rate == null ? null : rate / 2,
          duration: duration,
          sampleCount: count,
          bands: [
            for (final band in bands) FrequencyBandResult(band, null, reason)
          ],
        );

    if (points.length < 3 || window <= Duration.zero) {
      return unavailable('Waiting for $sensorName samples.');
    }

    // Preserve chronological arrival order. A backward device-time jump is a
    // new epoch, while genuine unsigned rollover continues normally.
    final timed = <_TimedVector>[];
    int? previousRaw;
    var elapsedMs = 0;
    for (final point in points) {
      final raw = point.sample.timestampMs & 0xffffffff;
      if (previousRaw != null) {
        final step = (raw - previousRaw) & 0xffffffff;
        if (step >= 0x80000000) {
          timed.clear();
          elapsedMs = 0;
        } else if (step == 0) {
          // Repeated timestamps cannot identify independent time samples.
          continue;
        } else {
          elapsedMs += step;
        }
      }
      previousRaw = raw;
      final values =
          point.sample.flags.sampleValid ? point.valuesFor(sensor) : null;
      timed.add(_TimedVector(elapsedMs, values));
    }
    if (timed.length < 3) {
      return unavailable('Waiting for distinct timestamps.');
    }

    final last = timed.last.ms;
    final recent =
        timed.where((p) => last - p.ms <= window.inMilliseconds).toList();
    if (recent.length < 3) {
      return unavailable('Waiting for $sensorName samples.',
          count: recent.length);
    }
    final duration = Duration(milliseconds: recent.last.ms - recent.first.ms);
    if (recent.any((p) => p.xyz == null)) {
      return unavailable(
          'The current window contains invalid $sensorName samples.',
          duration: duration,
          count: recent.length);
    }

    final intervals = <int>[
      for (var i = 1; i < recent.length; i++) recent[i].ms - recent[i - 1].ms,
    ]..sort();
    final medianMs = intervals.length.isOdd
        ? intervals[intervals.length ~/ 2].toDouble()
        : (intervals[intervals.length ~/ 2 - 1] +
                intervals[intervals.length ~/ 2]) /
            2;
    if (medianMs <= 0) {
      return unavailable('Invalid sample timing.',
          duration: duration, count: recent.length);
    }
    // Do not overstate bandwidth if occasional missing samples increase the
    // average interval while the median stays unchanged.
    final rate = math.min(1000.0 / medianMs,
        1000.0 * intervals.length / (recent.last.ms - recent.first.ms));
    // Permit minor timestamp quantization and jitter, but do not fabricate a
    // signal through a missing packet or a prolonged gap in a BLE stream.
    if (intervals.last > math.max(medianMs * 2.5, medianMs + 10)) {
      return unavailable(
          'A gap in the sample window prevents a reliable spectrum.',
          rate: rate,
          duration: duration,
          count: recent.length);
    }
    if (rate < 2 || duration.inMilliseconds < 1000) {
      return unavailable('Collecting a longer sample window.',
          rate: rate, duration: duration, count: recent.length);
    }

    final resampledIntervalMs = 1000.0 / rate;
    final n =
        ((recent.last.ms - recent.first.ms) / resampledIntervalMs).floor() + 1;
    if (n < 3 || n > 4096) {
      return unavailable('Unsupported sample rate or window size.',
          rate: rate, duration: duration, count: recent.length);
    }
    final vectors = List.generate(3, (_) => List<double>.filled(n, 0));
    var right = 1;
    for (var i = 0; i < n; i++) {
      final t = recent.first.ms + i * resampledIntervalMs;
      while (right < recent.length - 1 && recent[right].ms < t) {
        right++;
      }
      final before = recent[right - 1];
      final after = recent[right];
      final ratio = (t - before.ms) / (after.ms - before.ms);
      for (var axis = 0; axis < 3; axis++) {
        vectors[axis][i] =
            before.xyz![axis] + (after.xyz![axis] - before.xyz![axis]) * ratio;
      }
    }

    // Remove the mean per axis (gravity/DC), then use a Hann window to reduce
    // leakage from a movement cycle that does not fit exactly in the window.
    var energy = 0.0;
    for (final axis in vectors) {
      final mean = axis.reduce((a, b) => a + b) / n;
      for (var i = 0; i < n; i++) {
        axis[i] = (axis[i] - mean) *
            (0.5 - 0.5 * math.cos(2 * math.pi * i / (n - 1)));
        energy += axis[i] * axis[i];
      }
    }
    final durationSeconds = (n - 1) / rate;
    final spacing = rate / n;
    final safeMax =
        rate * 0.4; // leave a margin below Nyquist for usable bandwidth
    // Compute the usable spectrum once for comparisons both within each band
    // and against the strongest motion elsewhere in the window.
    final maxBin = (safeMax / spacing).floor();
    final powers = List<double>.filled(maxBin + 1, 0);
    for (var k = 1; k <= maxBin; k++) {
      final angle = 2 * math.pi * k / n;
      final c = math.cos(angle);
      final s = math.sin(angle);
      var realFactor = 1.0;
      var imagFactor = 0.0;
      final real = List<double>.filled(3, 0);
      final imag = List<double>.filled(3, 0);
      for (var i = 0; i < n; i++) {
        for (var axis = 0; axis < 3; axis++) {
          real[axis] += vectors[axis][i] * realFactor;
          imag[axis] += vectors[axis][i] * imagFactor;
        }
        final nextReal = realFactor * c - imagFactor * s;
        imagFactor = realFactor * s + imagFactor * c;
        realFactor = nextReal;
      }
      for (var axis = 0; axis < 3; axis++) {
        powers[k] += real[axis] * real[axis] + imag[axis] * imag[axis];
      }
    }
    final strongest = powers.reduce(math.max);
    final results = <FrequencyBandResult>[];
    for (final band in bands) {
      if (band.maxHz > safeMax) {
        results.add(FrequencyBandResult(
            band, null, 'Sample rate is too low for this entire band.'));
        continue;
      }
      if (durationSeconds * band.minHz < 2) {
        results.add(FrequencyBandResult(
            band, null, 'Collect at least two cycles in this band.'));
        continue;
      }
      if (energy < 1e-12) {
        results.add(FrequencyBandResult(
            band, null, 'No varying $sensorName signal in this window.'));
        continue;
      }
      final firstBin = (band.minHz / spacing).ceil();
      final lastBin = (band.maxHz / spacing).floor();
      if (lastBin - firstBin + 1 < 5) {
        results.add(FrequencyBandResult(
            band, null, 'Window is too short to resolve this band.'));
        continue;
      }
      var bestBin = firstBin;
      var bestPower = -1.0;
      for (var k = firstBin; k <= lastBin; k++) {
        if (powers[k] > bestPower) {
          bestPower = powers[k];
          bestBin = k;
        }
      }
      final sortedBand = powers.sublist(firstBin, lastBin + 1)..sort();
      final floor = sortedBand[sortedBand.length ~/ 2];
      // Heuristic display guard, not a clinical threshold or statistical proof:
      // suppress tiny leakage beside a strong movement and broad/flat noise.
      if (bestPower < strongest * 0.01 || bestPower < floor * 5) {
        results.add(FrequencyBandResult(band, null,
            'No distinct peak: this band is weak or lacks spectral contrast.'));
        continue;
      }
      results.add(FrequencyBandResult(band, bestBin * spacing, null));
    }
    return ImuFrequencyAnalysis(
        error: null,
        sampleRateHz: rate,
        nyquistHz: rate / 2,
        duration: duration,
        sampleCount: recent.length,
        bands: results);
  }
}

class _TimedVector {
  final int ms;
  final List<double>? xyz;
  const _TimedVector(this.ms, this.xyz);
}
