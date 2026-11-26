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
  static const _gapReason =
      'A gap in the sample window prevents a reliable spectrum.';

  /// Select [percussionBandIndex] to use a fresh contiguous window after a
  /// short timestamp stall. On the accelerometer, recurrence can also support
  /// a marginal peak. With [defaultBands], the first band is selected.
  static ImuFrequencyAnalysis analyze(
    List<RawImuHistoryPoint> points, {
    Duration window = const Duration(seconds: 8),
    List<FrequencyBand> bands = defaultBands,
    RawSensorType sensor = RawSensorType.accelerometer,
    int? percussionBandIndex,
  }) {
    final index =
        percussionBandIndex ?? (identical(bands, defaultBands) ? 0 : null);
    if (index != null) {
      RangeError.checkValidIndex(index, bands, 'percussionBandIndex');
    }
    return _analyze(points, window, bands, sensor, percussionBandIndex: index);
  }

  static ImuFrequencyAnalysis _analyze(
    List<RawImuHistoryPoint> points,
    Duration window,
    List<FrequencyBand> bands,
    RawSensorType sensor, {
    required int? percussionBandIndex,
    bool afterGap = false,
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
      timed.add(_TimedVector(elapsedMs, values, point));
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
    final maxIntervalMs = math.max(medianMs * 2.5, medianMs + 10);
    if (intervals.last > maxIntervalMs) {
      // A short stall or a few missing samples may leave enough fresh data
      // for percussion. Restart the spectrum after the last gap.
      if (percussionBandIndex != null &&
          !afterGap &&
          intervals.last <= math.min(120, medianMs * 4 + 2)) {
        final first = _startAfterShortGaps(recent, maxIntervalMs, medianMs);
        if (first != null && last - recent[first].ms >= 2000) {
          final suffixMs = last - recent[first].ms;
          final suffix = _analyze(
              points, Duration(milliseconds: suffixMs), bands, sensor,
              percussionBandIndex: percussionBandIndex, afterGap: true);
          if (suffix.bands[percussionBandIndex].peakHz != null) return suffix;
        }
      }
      return unavailable(_gapReason,
          rate: rate, duration: duration, count: recent.length);
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
    final magnitudes =
        percussionBandIndex != null && sensor == RawSensorType.accelerometer
            ? List<double>.filled(n, 0)
            : null;
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
      if (magnitudes != null) {
        final x = vectors[0][i];
        final y = vectors[1][i];
        final z = vectors[2][i];
        magnitudes[i] = math.sqrt(x * x + y * y + z * z);
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
    for (final (index, band) in bands.indexed) {
      if (afterGap && index != percussionBandIndex) {
        results.add(FrequencyBandResult(band, null, _gapReason));
        continue;
      }
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
      // A short suffix has coarse bins. Include the bin just outside each
      // edge so a peak near a band boundary can be placed by interpolation.
      final searchFirst = afterGap ? math.max(1, firstBin - 1) : firstBin;
      final searchLast = afterGap ? math.min(maxBin, lastBin + 1) : lastBin;
      for (var k = searchFirst; k <= searchLast; k++) {
        if (powers[k] > bestPower) {
          bestPower = powers[k];
          bestBin = k;
        }
      }
      final sortedBand = powers.sublist(firstBin, lastBin + 1)..sort();
      final floor = sortedBand[sortedBand.length ~/ 2];
      final peakHz = afterGap
          ? _interpolateBin(powers, bestBin) * spacing
          : bestBin * spacing;
      // Heuristic display guard, not a clinical threshold or statistical proof:
      // suppress tiny leakage beside a strong movement and broad/flat noise.
      // A marginal percussion peak needs more relative power and independent
      // evidence that the candidate period repeats in recent acceleration.
      final confirmed = index == percussionBandIndex &&
          magnitudes != null &&
          bestPower >= strongest * 0.1 &&
          bestPower >= floor * 3 &&
          bestPower < floor * 5 &&
          _hasAccelerationRecurrence(magnitudes, rate / peakHz);
      if ((afterGap && (peakHz < band.minHz || peakHz > band.maxHz)) ||
          bestPower < strongest * 0.01 ||
          (bestPower < floor * 5 && !confirmed)) {
        results.add(FrequencyBandResult(band, null,
            'No distinct peak: this band is weak or lacks spectral contrast.'));
        continue;
      }
      results.add(FrequencyBandResult(band, peakHz, null));
    }
    return ImuFrequencyAnalysis(
        error: null,
        sampleRateHz: rate,
        nyquistHz: rate / 2,
        duration: duration,
        sampleCount: recent.length,
        bands: results);
  }

  static double _interpolateBin(List<double> powers, int bin) {
    if (bin <= 1 || bin + 1 == powers.length) return bin.toDouble();
    final left = powers[bin - 1];
    final center = powers[bin];
    final right = powers[bin + 1];
    if (left <= 0 || right <= 0 || center < math.max(left, right)) {
      return bin.toDouble();
    }
    final curvature = 2 * math.log(center) - math.log(left) - math.log(right);
    if (curvature <= 0) return bin.toDouble();
    return bin + 0.5 * (math.log(right) - math.log(left)) / curvature;
  }

  static int? _startAfterShortGaps(
      List<_TimedVector> points, double maxInterval, double nominalInterval) {
    int? first;
    for (var i = 1; i < points.length; i++) {
      final elapsed = points[i].ms - points[i - 1].ms;
      if (elapsed <= maxInterval) continue;
      final before = points[i - 1].source;
      final after = points[i].source;
      final previous = before.sample;
      final current = after.sample;
      final mask = current.version == 2 ? 0xffff : 0xffffffff;
      final step = (current.sequence - previous.sequence) & mask;
      if (current.version != previous.version ||
          after.deviceId != before.deviceId ||
          after.sessionId != before.sessionId ||
          step < 1 ||
          step > 4 ||
          step * nominalInterval > elapsed + 2) {
        return null;
      }
      first = i;
    }
    return first;
  }

  static bool _hasAccelerationRecurrence(
      List<double> magnitudes, double period) {
    final end = magnitudes.length;
    // Use two disjoint recent blocks, each long enough to compare multiple
    // cycles. Cap the lookback so old impacts cannot corroborate a quiet tail.
    final blockSize = math.min(end ~/ 2, (6 * period).ceil());
    if (period < 8 || blockSize < 2.5 * period) return false;

    final values = magnitudes.sublist(end - 2 * blockSize);
    // Smooth each block symmetrically to reduce sample-to-sample ringing
    // without shifting the cadence or sharing samples across the boundary.
    for (final first in [0, blockSize]) {
      var previous = values[first];
      for (var i = first + 1; i < first + blockSize - 1; i++) {
        final current = values[i];
        values[i] = (previous + 2 * current + values[i + 1]) / 4;
        previous = current;
      }
    }
    // Allow for FFT bin quantization and require a common lag in both blocks.
    var bestRepeat = 0.4;
    int? bestLag;
    for (var lag = (0.9 * period).ceil();
        lag <= (1.1 * period).floor();
        lag++) {
      final repeat = math.min(_lagCorrelation(values, 0, blockSize, lag),
          _lagCorrelation(values, blockSize, values.length, lag));
      if (repeat >= bestRepeat) {
        bestRepeat = repeat;
        bestLag = lag;
      }
    }
    return bestLag != null &&
        _hasLagContrast(values, 0, blockSize, bestLag) &&
        _hasLagContrast(values, blockSize, values.length, bestLag);
  }

  static bool _hasLagContrast(
      List<double> values, int first, int end, int lag) {
    final repeat = _lagCorrelation(values, first, end, lag);

    // A faster repeating waveform can correlate again at a multiple of its
    // period. Require the candidate to stand above shorter lags and its flank.
    final limit = repeat - 0.15;
    for (var shorter = (lag / 4).round();
        shorter <= (lag * 0.75).round();
        shorter++) {
      if (_lagCorrelation(values, first, end, shorter) > limit) return false;
    }
    return _lagCorrelation(values, first, end, (lag * 1.25).round()) <= limit;
  }

  static double _lagCorrelation(
      List<double> values, int first, int end, int lag) {
    var sumX = 0.0;
    var sumY = 0.0;
    var sumXX = 0.0;
    var sumYY = 0.0;
    var sumXY = 0.0;
    final count = end - first - lag;
    final origin = values[first];
    for (var i = first; i < end - lag; i++) {
      final x = values[i] - origin;
      final y = values[i + lag] - origin;
      sumX += x;
      sumY += y;
      sumXX += x * x;
      sumYY += y * y;
      sumXY += x * y;
    }
    final varX = sumXX - sumX * sumX / count;
    final varY = sumYY - sumY * sumY / count;
    if (varX <= 0 || varY <= 0) return 0;
    return (sumXY - sumX * sumY / count) / math.sqrt(varX * varY);
  }
}

class _TimedVector {
  final int ms;
  final List<double>? xyz;
  final RawImuHistoryPoint source;
  const _TimedVector(this.ms, this.xyz, this.source);
}
