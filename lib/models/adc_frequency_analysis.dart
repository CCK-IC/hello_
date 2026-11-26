import 'dart:math' as math;

import 'adc_history.dart';
import 'imu_frequency_analysis.dart';
import 'raw_imu_history.dart';

/// Estimates percussion from one ADC channel and corroborates it with IMU
/// impacts. Vibration uses IMU samples acquired during sustained ADC highs.
///
/// Input is in acquisition order and scoped to the same board and session by
/// the caller. All timing uses the shared unsigned device clock.
class AdcFrequencyAnalyzer {
  static const _windowMs = 12000;
  static const _maxSamples = 4096;
  static const _maxStreamAgeMs = 1500;
  static const _minAdcContrast = 8.0;

  /// Uses the first two [bands] for percussion and vibration, respectively.
  /// [channel] is zero-based. An empty input disables the corresponding stream.
  static ({ImuFrequencyAnalysis adc, ImuFrequencyAnalysis fused}) analyze(
    List<AdcHistoryPoint> adcPoints,
    List<RawImuHistoryPoint> imuPoints, {
    required List<FrequencyBand> bands,
    required RawSensorType sensor,
    int channel = 0,
    int? highThreshold,
  }) {
    if (bands.length < 2 ||
        bands.take(2).any((band) =>
            !band.minHz.isFinite ||
            !band.maxHz.isFinite ||
            band.minHz <= 0 ||
            band.maxHz <= band.minHz)) {
      throw ArgumentError.value(
          bands, 'bands', 'Expected two frequency ranges');
    }
    final percussion = bands[0];
    final vibration = bands[1];
    final anchor = adcPoints.isEmpty ? 0 : adcPoints.last.sample.timestampMs;
    final adcReadings = _adcReadings(
        _recent(adcPoints, (p) => p.sample.timestampMs, anchor), channel);
    final adcWindow = _continuousTail(adcReadings.values);
    final adcTiming = _Timing.measure(adcWindow, 'ADC');
    final adcError = adcReadings.error ?? adcTiming.error;
    final FrequencyBandResult adcBand;
    if (adcError != null) {
      adcBand = FrequencyBandResult(percussion, null, adcError);
    } else {
      final rate = adcTiming.rateHz!;
      adcBand = _tapEnvelope(adcWindow, rate, percussion)?.band ??
          _percussion(adcWindow, rate, percussion).band;
    }
    final adc = adcTiming.analysis([adcBand], error: adcError);

    ImuFrequencyAnalysis unavailable(String reason, {_Timing? timing}) =>
        (timing ?? const _Timing()).analysis([
          FrequencyBandResult(percussion, null, reason),
          FrequencyBandResult(vibration, null, reason),
        ], error: reason);

    if (adcReadings.error case final error?) {
      return (adc: adc, fused: unavailable(error));
    }
    if (adcWindow.isEmpty || imuPoints.isEmpty) {
      return (
        adc: adc,
        fused: unavailable('Waiting for both ADC and IMU samples.'),
      );
    }

    final gloveId = adcPoints.last.sample.gloveId;
    final imuRecent = _recent(imuPoints, (p) => p.sample.timestampMs, anchor);
    final imuWindow = _continuousTail(imuRecent.where((point) {
      final sample = point.value.sample;
      return sample.gloveId == gloveId &&
          sample.flags.sampleValid &&
          (sensor != RawSensorType.magnetometer ||
              !sample.flags.magnetometerOverflow) &&
          point.value.valuesFor(sensor) != null;
    }).toList());
    if (imuWindow.isEmpty) {
      return (adc: adc, fused: unavailable('Waiting for valid IMU samples.'));
    }
    final start = math.max(adcWindow.first.ms, imuWindow.first.ms);
    final end = math.min(adcWindow.last.ms, imuWindow.last.ms);
    if (start >= end) {
      return (
        adc: adc,
        fused: unavailable('ADC and IMU windows do not overlap.')
      );
    }
    // Compare only the shared capture. The streams can deliver different
    // batch lengths, so their newest samples need not be nearly simultaneous.
    final newestCapture = math.max(0, imuRecent.last.ms);
    if (newestCapture - end > _maxStreamAgeMs) {
      return (adc: adc, fused: unavailable('One device stream is stale.'));
    }

    final sharedAdc =
        adcWindow.where((p) => p.ms >= start && p.ms <= end).toList();
    final sharedImu =
        imuWindow.where((p) => p.ms >= start && p.ms <= end).toList();
    final sharedAdcTiming = _Timing.measure(sharedAdc, 'ADC');
    final imuTiming = _Timing.measure(sharedImu, 'IMU');
    final timingError = sharedAdcTiming.error ?? imuTiming.error;
    if (timingError != null) {
      return (adc: adc, fused: unavailable(timingError, timing: imuTiming));
    }
    final vectors = [
      for (final point in sharedImu) point.value.valuesFor(sensor)!
    ];

    final adcRate = sharedAdcTiming.rateHz!;
    final imuRate = imuTiming.rateHz!;
    final envelope = _tapEnvelope(sharedAdc, adcRate, percussion);
    final fusedPercussion = envelope == null
        ? _corroborate(_percussion(sharedAdc, adcRate, percussion), sharedImu,
            vectors, imuRate, sensor)
        : _corroborateEnvelope(envelope, sharedImu, vectors, imuRate, sensor);
    final fusedVibration = _vibration(sharedAdc, sharedImu, vibration, sensor,
        highThreshold: highThreshold);
    return (
      adc: adc,
      fused: imuTiming.analysis([fusedPercussion, fusedVibration]),
    );
  }

  static ({List<_Timed<double>> values, String? error}) _adcReadings(
      List<_Timed<AdcHistoryPoint>> points, int channel) {
    if (channel < 0 || channel >= 8) {
      return (values: [], error: 'ADC channel is out of range.');
    }
    if (points.isNotEmpty &&
        channel >= points.last.value.sample.activeChannelCount) {
      return (values: [], error: 'The selected ADC channel is inactive.');
    }
    final values = <_Timed<double>>[];
    for (final point in points) {
      final sample = point.value.sample;
      if (!sample.sampleValid ||
          sample.gloveId != points.last.value.sample.gloveId ||
          channel >= sample.activeChannelCount) {
        continue;
      }
      values.add((ms: point.ms, value: sample.channels[channel].toDouble()));
    }
    if (points.isNotEmpty &&
        (values.isEmpty || points.last.ms - values.last.ms > _maxStreamAgeMs)) {
      return (values: [], error: 'Waiting for valid ADC samples.');
    }
    return (values: values, error: null);
  }

  static _Percussion _percussion(
      List<_Timed<double>> points, double rateHz, FrequencyBand band) {
    _Percussion unavailable(String reason) => (
          band: FrequencyBandResult(band, null, reason),
          peaks: <int>[],
        );

    if (band.minHz > 0.4 * rateHz) {
      return unavailable('ADC sample rate is too low for the percussion band.');
    }

    final levels = points.map((p) => p.value).toList()..sort();
    final baseline = _quantile(levels, 0.2);
    final contrast = _quantile(levels, 0.995) - baseline;
    final changes = [
      for (var i = 1; i < points.length; i++)
        (points[i].value - points[i - 1].value).abs(),
    ]..sort();
    // A median step measures the noise floor without letting a few sharp
    // taps dominate it. A lower fraction of the overall range keeps weaker
    // strikes visible when stronger strikes occur in the same window.
    final prominence = math.max(_minAdcContrast, 3.5 * _quantile(changes, 0.5));
    if (contrast < prominence) {
      return unavailable('No distinct ADC excursions in the window.');
    }
    final threshold = baseline + math.max(prominence, 0.22 * contrast);
    final peaks = _peaks(points, threshold);
    return (
      band: _cadence(peaks, band, maxUsableHz: 0.4 * rateHz),
      peaks: peaks
    );
  }

  static ({int start, FrequencyBandResult band, List<int> peaks})? _tapEnvelope(
      List<_Timed<double>> points, double rateHz, FrequencyBand band) {
    final start = points.last.ms -
        math.min(_windowMs, math.max(4000, 4000 / band.minHz)).round();
    final recent = points.where((point) => point.ms >= start).toList();
    if (recent.length < 3) return null;
    final levels = recent.map((p) => p.value).toList()..sort();
    final steps = [
      for (var i = 1; i < recent.length; i++)
        (recent[i].value - recent[i - 1].value).abs(),
    ]..sort();
    final noise = 3.5 * _quantile(steps, 0.5);
    if (noise < _minAdcContrast) {
      return null; // The direct peak path handles clean signals.
    }
    final floor = _quantile(levels, 0.2) + noise;
    final excess = [0.0];
    for (final point in recent) {
      excess.add(excess.last + math.max(0, point.value - floor));
    }
    // Average excess signal over 40 ms to reduce chatter without averaging
    // small taps with the long quiet intervals between them.
    var left = 0;
    var right = 0;
    final envelope = <_Timed<double>>[];
    for (final point in recent) {
      while (recent[left].ms < point.ms - 20) {
        left++;
      }
      while (right < recent.length && recent[right].ms <= point.ms + 20) {
        right++;
      }
      envelope.add((
        ms: point.ms,
        value: (excess[right] - excess[left]) / (right - left)
      ));
    }
    final sorted = envelope.map((point) => point.value).toList()..sort();
    final threshold = math.max(noise / 4, _quantile(sorted, 0.995) * 0.22);
    final peaks = _contactPeaks(envelope, threshold, band);
    return (
      start: start,
      band: _cadence(peaks, band, maxUsableHz: 0.4 * rateHz),
      peaks: peaks
    );
  }

  static FrequencyBandResult _corroborateEnvelope(
      ({int start, FrequencyBandResult band, List<int> peaks}) candidate,
      List<_Timed<RawImuHistoryPoint>> imu,
      List<List<double>> vectors,
      double rateHz,
      RawSensorType sensor) {
    final band = candidate.band.band;
    const reason = 'ADC contacts lack synchronized IMU impacts.';
    final maxUsableHz = 0.4 * rateHz;
    if (band.minHz > maxUsableHz) {
      return FrequencyBandResult(
          band, null, 'IMU sample rate is too low for the percussion band.');
    }
    if (candidate.peaks.length < 3) {
      return FrequencyBandResult(
          band, null, 'Need at least three distinct ADC contacts.');
    }
    final changes = <_Timed<double>>[];
    for (var i = 1; i < imu.length; i++) {
      if (imu[i].ms < candidate.start) continue;
      var energy = 0.0;
      if (imu[i].ms - imu[i - 1].ms <= 2500 / rateHz) {
        for (var axis = 0; axis < 3; axis++) {
          final delta = vectors[i][axis] - vectors[i - 1][axis];
          energy += delta * delta;
        }
      }
      changes.add((ms: imu[i].ms, value: math.sqrt(energy)));
    }
    if (changes.length < 3) return FrequencyBandResult(band, null, reason);
    final toleranceMs = (1500 / rateHz).clamp(25.0, 35.0);
    final levels = changes.map((point) => point.value).toList()..sort();
    final baseline = _quantile(levels, 0.5);
    final contrast = _quantile(levels, 0.985) - baseline;
    final levelContrast = _minimumImuImpactContrast(sensor);
    // At higher sample rates, the same motion produces smaller steps.
    final minimumContrast = levelContrast * math.min(1, 100 / rateHz);
    final changeImpacts = contrast < minimumContrast
        ? <int>[]
        : _peaks(changes, baseline + 0.45 * contrast,
            minSeparationMs: math.min(110, 500 / band.maxHz).round());
    final unavailable = FrequencyBandResult(band, null, reason);

    ({FrequencyBandResult result, int support}) corroborate(List<int> impacts,
        {List<int> otherImpacts = const []}) {
      final matched = _matchImpacts(candidate.peaks, impacts, toleranceMs,
          allowExtraImuImpacts: true);
      if (matched.isEmpty) return (result: unavailable, support: 0);
      // A missing corroboration cannot stretch two contacts into one cycle.
      final peaks = candidate.peaks;
      final periods = <int>[];
      final impactIntervals = <({int start, int end})>[];
      final fastestPeriod = 1000 / math.min(band.maxHz, maxUsableHz);
      final slowestPeriod = 1000 / band.minHz;
      for (var i = 1; i < matched.length; i++) {
        final previous = matched[i - 1];
        final next = matched[i];
        if (next.adcIndex != previous.adcIndex + 1) continue;
        final period = peaks[next.adcIndex] - peaks[previous.adcIndex];
        periods.add(period);
        if (period >= fastestPeriod && period <= slowestPeriod) {
          impactIntervals.add(
              (start: impacts[previous.imuIndex], end: impacts[next.imuIndex]));
        }
      }
      if (_hasMidpointImpacts(impactIntervals, impacts) ||
          _hasMidpointImpacts(impactIntervals, otherImpacts)) {
        return (result: unavailable, support: 0);
      }
      final result =
          _cadenceFromPeriods(periods, band, maxUsableHz: maxUsableHz);
      return (
        result: result,
        support: result.peakHz == null ? 0 : matched.length
      );
    }

    final primary = corroborate(changeImpacts);
    if (primary.support > 0) return primary.result;

    // Several weaker changes can mark contact while a sharp rebound dominates
    // the unsmoothed peak. Average over a short portion of the fastest cycle.
    final smoothed = _centeredMean(changes, math.min(30, 150 / band.maxHz));
    final smoothLevels = smoothed.map((point) => point.value).toList()..sort();
    final smoothBaseline = _quantile(smoothLevels, 0.5);
    final smoothContrast = _quantile(smoothLevels, 0.9) - smoothBaseline;
    final minSeparationMs = math.min(80, 400 / band.maxHz).round();
    if (smoothContrast >= minimumContrast) {
      final smoothedResult = corroborate(
          _peaks(smoothed, smoothBaseline + 0.35 * smoothContrast,
              minSeparationMs: minSeparationMs),
          otherImpacts: changeImpacts);
      if (smoothedResult.support > 0) return smoothedResult.result;
    }

    // Sparse samples can capture the level response without resolving the
    // sharp changes around it. Compare level peaks in the same contact window.
    final first = imu.indexWhere((point) => point.ms >= candidate.start);
    var best = primary;
    for (final impacts in _signedImuImpacts(imu, vectors, levelContrast,
        first: first, minSeparationMs: minSeparationMs)) {
      final result = corroborate(impacts, otherImpacts: changeImpacts);
      if (result.support > best.support) best = result;
    }
    if (best.support > 0) return best.result;
    final magnitudeResult = corroborate(
        _magnitudeImuImpacts(imu, vectors, levelContrast,
            first: first, minSeparationMs: minSeparationMs),
        otherImpacts: changeImpacts);
    return magnitudeResult.support > 0
        ? magnitudeResult.result
        : primary.result;
  }

  static bool _hasMidpointImpacts(
      List<({int start, int end})> intervals, List<int> impacts) {
    if (intervals.length < 2 || impacts.isEmpty) return false;
    var next = 0;
    var midpointCount = 0;
    for (final interval in intervals) {
      final span = interval.end - interval.start;
      final earliest = interval.start + 0.4 * span;
      final latest = interval.start + 0.6 * span;
      while (next < impacts.length && impacts[next] < earliest) {
        next++;
      }
      if (next < impacts.length && impacts[next] <= latest) midpointCount++;
    }
    // In a doubled train the first and last matches can give the slower
    // stream a majority even when there is an extra impact every cycle.
    return 3 * midpointCount >= 2 * intervals.length;
  }

  static double _minimumImuImpactContrast(RawSensorType sensor) =>
      switch (sensor) {
        RawSensorType.accelerometer => 0.002, // g
        RawSensorType.gyroscope => 0.25, // degrees/s
        RawSensorType.magnetometer => 4.0, // counts
      };

  static FrequencyBandResult _corroborate(
    _Percussion candidate,
    List<_Timed<RawImuHistoryPoint>> imu,
    List<List<double>> vectors,
    double rateHz,
    RawSensorType sensor,
  ) {
    final band = candidate.band.band;
    final maxUsableHz = 0.4 * rateHz;
    if (band.minHz > maxUsableHz) {
      return FrequencyBandResult(
          band, null, 'IMU sample rate is too low for the percussion band.');
    }
    final adcPeaks = candidate.peaks;
    if (adcPeaks.length < 3) {
      return FrequencyBandResult(band, null,
          'Need at least three ADC peaks to corroborate percussion.');
    }

    // Evaluate each axis and polarity independently. A fixed choice of sign
    // avoids counting both lobes of a single oscillation as separate impacts.
    final minimumContrast = _minimumImuImpactContrast(sensor);
    final toleranceMs = (1000 / rateHz).clamp(20.0, 35.0);
    var synchronized = false;
    var bestSupport = 0;
    FrequencyBandResult? best;

    void consider(List<int> impacts) {
      final matched = _matchImpacts(adcPeaks, impacts, toleranceMs);
      if (matched.isEmpty) return;
      synchronized = true;
      if (matched.length <= bestSupport) return;
      final result = _cadence(
          [for (final pair in matched) adcPeaks[pair.adcIndex]], band,
          maxUsableHz: maxUsableHz);
      if (result.peakHz != null) {
        best = result;
        bestSupport = matched.length;
      }
    }

    for (final impacts in _signedImuImpacts(imu, vectors, minimumContrast)) {
      consider(impacts);
    }
    if (best == null) {
      // Taps in different directions may never appear together on a single
      // axis. Check their magnitude relative to the window's resting vector.
      consider(_magnitudeImuImpacts(imu, vectors, minimumContrast));
    }
    return best ??
        FrequencyBandResult(
          band,
          null,
          synchronized
              ? 'Need at least two synchronized tap intervals within the percussion band.'
              : 'ADC peaks lack synchronized IMU impacts.',
        );
  }

  static Iterable<List<int>> _signedImuImpacts(
    List<_Timed<RawImuHistoryPoint>> imu,
    List<List<double>> vectors,
    double minimumContrast, {
    int first = 0,
    int minSeparationMs = 0,
  }) sync* {
    for (var axis = 0; axis < 3; axis++) {
      for (final sign in [1, -1]) {
        yield _imuLevelPeaks([
          for (var i = first; i < imu.length; i++)
            (ms: imu[i].ms, value: sign * vectors[i][axis]),
        ], minimumContrast, minSeparationMs);
      }
    }
  }

  static List<int> _magnitudeImuImpacts(
    List<_Timed<RawImuHistoryPoint>> imu,
    List<List<double>> vectors,
    double minimumContrast, {
    int first = 0,
    int minSeparationMs = 0,
  }) {
    final center = [
      for (var axis = 0; axis < 3; axis++)
        _quantile(
            [for (var i = first; i < vectors.length; i++) vectors[i][axis]]
              ..sort(),
            0.5),
    ];
    final magnitudes = <_Timed<double>>[];
    for (var i = first; i < vectors.length; i++) {
      var energy = 0.0;
      for (var axis = 0; axis < 3; axis++) {
        final delta = vectors[i][axis] - center[axis];
        energy += delta * delta;
      }
      magnitudes.add((ms: imu[i].ms, value: math.sqrt(energy)));
    }
    return _imuLevelPeaks(magnitudes, minimumContrast, minSeparationMs);
  }

  static List<int> _imuLevelPeaks(List<_Timed<double>> signal,
      double minimumContrast, int minSeparationMs) {
    final levels = signal.map((p) => p.value).toList()..sort();
    final baseline = _quantile(levels, 0.5);
    final contrast = _quantile(levels, 0.985) - baseline;
    if (contrast < minimumContrast) return [];
    return _peaks(signal, baseline + 0.5 * contrast,
        minSeparationMs: minSeparationMs);
  }

  static FrequencyBandResult _vibration(
    List<_Timed<double>> adc,
    List<_Timed<RawImuHistoryPoint>> imu,
    FrequencyBand band,
    RawSensorType sensor, {
    int? highThreshold,
  }) {
    double enterThreshold;
    double holdThreshold;
    if (highThreshold != null) {
      enterThreshold = holdThreshold = highThreshold.toDouble();
    } else {
      final levels = adc.map((p) => p.value).toList()..sort();
      final baseline = _quantile(levels, 0.03);
      final contrast = _quantile(levels, 0.9) - baseline;
      if (contrast < _minAdcContrast) {
        return FrequencyBandResult(
            band, null, 'No ADC-high contrast in the window.');
      }
      // A brief release can establish the low reference. After entry, allow
      // the grip to settle below the entry level while it remains high.
      enterThreshold = baseline + 0.65 * contrast;
      holdThreshold = baseline + 0.45 * contrast;
    }
    final intervals = <({int first, int end})>[];
    var nextImu = 0;
    for (final run in _adcHighRuns(adc, enterThreshold, holdThreshold)) {
      while (nextImu < imu.length && imu[nextImu].ms < adc[run.first].ms) {
        nextImu++;
      }
      final first = nextImu;
      while (nextImu < imu.length && imu[nextImu].ms <= adc[run.end - 1].ms) {
        nextImu++;
      }
      // The existing analyzer additionally requires two cycles at the band's
      // lower edge and enough frequency bins to resolve a peak.
      if (nextImu - first >= 3 && imu[nextImu - 1].ms - imu[first].ms >= 1000) {
        intervals.add((first: first, end: nextImu));
      }
    }
    intervals.sort((a, b) => (b.end - b.first).compareTo(a.end - a.first));
    FrequencyBandResult? firstResult;
    // Analyze each eligible run separately, longest first. A release longer
    // than the dip allowance ends the spectrum window.
    for (final run in intervals) {
      final result = ImuFrequencyAnalyzer.analyze(
        [for (var i = run.first; i < run.end; i++) imu[i].value],
        bands: [band],
        sensor: sensor,
        window: const Duration(milliseconds: _windowMs),
      ).bands.single;
      if (result.peakHz != null) return result;
      firstResult ??= result;
    }
    return firstResult ??
        FrequencyBandResult(
            band, null, 'Waiting for a sustained ADC-high interval.');
  }
}

typedef _Timed<T> = ({int ms, T value});
typedef _Percussion = ({FrequencyBandResult band, List<int> peaks});

/// Typical rate of observed events. Pauses and rebound intervals outside the
/// selected band do not contribute. Do not synthesize missed events.
FrequencyBandResult _cadence(List<int> peaks, FrequencyBand band,
        {double maxUsableHz = double.infinity}) =>
    _cadenceFromPeriods([
      for (var i = 1; i < peaks.length; i++) peaks[i] - peaks[i - 1],
    ], band, maxUsableHz: maxUsableHz);

FrequencyBandResult _cadenceFromPeriods(
    List<int> observedPeriods, FrequencyBand band,
    {required double maxUsableHz}) {
  final fastestPeriod = 1000 / math.min(band.maxHz, maxUsableHz);
  final slowestPeriod = 1000 / band.minHz;
  final periods = <int>[];
  var tooFast = 0;
  for (final period in observedPeriods) {
    if (period < fastestPeriod) {
      tooFast++;
    } else if (period <= slowestPeriod) {
      periods.add(period);
    }
  }
  if (periods.length < 2 || tooFast > periods.length) {
    return FrequencyBandResult(band, null,
        'Need at least two clear tap intervals within the percussion band.');
  }
  periods.sort();
  return FrequencyBandResult(band, 1000 / _quantile(periods, 0.5), null);
}

int _deltaMs(int a, int b) => ((a - b + 0x80000000) & 0xffffffff) - 0x80000000;

List<_Timed<T>> _recent<T>(
    List<T> points, int Function(T) timestamp, int anchor) {
  if (points.isEmpty) return [];
  final latest = timestamp(points.last);
  var previous = latest;
  final newestMs = _deltaMs(latest, anchor);
  final recent = <_Timed<T>>[(ms: newestMs, value: points.last)];
  var ms = newestMs;
  for (var i = points.length - 2;
      i >= 0 && recent.length < AdcFrequencyAnalyzer._maxSamples;
      i--) {
    final raw = timestamp(points[i]);
    final step = _deltaMs(previous, raw);
    if (step < 0) break; // A backward jump starts a new clock epoch.
    if (step == 0) continue; // Duplicate timestamp adds no independent sample.
    ms -= step;
    if (newestMs - ms > AdcFrequencyAnalyzer._windowMs) break;
    recent.add((ms: ms, value: points[i]));
    previous = raw;
  }
  return recent.reversed.toList();
}

/// Keep recent evidence after a sustained interruption. Minor gaps from a
/// dropped or invalid sample keep their real timestamps in the window.
List<_Timed<T>> _continuousTail<T>(List<_Timed<T>> points) {
  if (points.length < 3) return points;
  final steps = [
    for (var i = 1; i < points.length; i++) points[i].ms - points[i - 1].ms,
  ];
  final typical = _quantile([...steps]..sort(), 0.5);
  final interruption = math.max(typical * 3.25, typical + 20);
  final lastGap = steps.lastIndexWhere((step) => step > interruption);
  return lastGap == -1 ? points : points.sublist(lastGap + 1);
}

class _Timing {
  final int count;
  final Duration duration;
  final double? rateHz;
  final String? error;

  const _Timing({
    this.count = 0,
    this.duration = Duration.zero,
    this.rateHz,
    this.error,
  });

  static _Timing measure<T>(List<_Timed<T>> points, String label) {
    final count = points.length;
    final span = count < 2 ? 0 : points.last.ms - points.first.ms;
    final duration = Duration(milliseconds: span);
    if (count < 3) {
      return _Timing(
          count: count,
          duration: duration,
          error: 'Waiting for $label samples.');
    }
    // Use the full elapsed time for the rate so integer timestamp
    // quantization and asymmetric jitter do not bias the median interval.
    final rate = 1000 * (count - 1) / span;
    return _Timing(count: count, duration: duration, rateHz: rate);
  }

  ImuFrequencyAnalysis analysis(List<FrequencyBandResult> bands,
          {String? error}) =>
      ImuFrequencyAnalysis(
        error: error,
        sampleRateHz: rateHz,
        nyquistHz: rateHz == null ? null : rateHz! / 2,
        duration: duration,
        sampleCount: count,
        bands: bands,
      );
}

double _quantile(List<num> sorted, double fraction) {
  final index = fraction * (sorted.length - 1);
  final low = sorted[index.floor()];
  return low + (sorted[index.ceil()] - low) * (index - index.floor());
}

List<_Timed<double>> _centeredMean(
    List<_Timed<double>> signal, double halfWidthMs) {
  final smoothed = <_Timed<double>>[];
  var left = 0;
  var right = 0;
  var sum = 0.0;
  for (final point in signal) {
    while (
        right < signal.length && signal[right].ms <= point.ms + halfWidthMs) {
      sum += signal[right++].value;
    }
    while (signal[left].ms < point.ms - halfWidthMs) {
      sum -= signal[left++].value;
    }
    smoothed.add((ms: point.ms, value: sum / (right - left)));
  }
  return smoothed;
}

Iterable<({int first, int end})> _aboveThreshold(
    List<_Timed<double>> signal, double threshold) sync* {
  int? first;
  for (var i = 0; i < signal.length; i++) {
    if (signal[i].value >= threshold) {
      first ??= i;
    } else if (first != null) {
      yield (first: first, end: i);
      first = null;
    }
  }
  if (first != null) yield (first: first, end: signal.length);
}

List<int> _peaks(List<_Timed<double>> signal, double threshold,
    {int minSeparationMs = 0}) {
  final peaks = <_Timed<double>>[];
  for (final run in _aboveThreshold(signal, threshold)) {
    // A partial excursion at the window edge has no reliable maximum.
    if (run.first == 0 || run.end == signal.length) continue;
    var firstMax = run.first;
    var lastMax = firstMax;
    for (var i = firstMax + 1; i < run.end; i++) {
      if (signal[i].value > signal[firstMax].value) firstMax = lastMax = i;
      if (signal[i].value == signal[firstMax].value) lastMax = i;
    }
    final peak = (
      ms: (signal[firstMax].ms + signal[lastMax].ms) ~/ 2,
      value: signal[firstMax].value,
    );
    if (peaks.isNotEmpty && peak.ms - peaks.last.ms < minSeparationMs) {
      if (peak.value > peaks.last.value) peaks[peaks.length - 1] = peak;
    } else {
      peaks.add(peak);
    }
  }
  return [for (final peak in peaks) peak.ms];
}

List<int> _contactPeaks(
    List<_Timed<double>> signal, double threshold, FrequencyBand band) {
  final peaks = <int>[];
  final releaseThreshold = threshold * 0.55;
  final maxContactMs = math.min(450, 500 / band.minHz);
  int? started;
  int? released;
  _Timed<double>? peak;
  for (final point in signal) {
    if (started == null) {
      if (point.value >= threshold) {
        started = point.ms;
        peak = point;
      }
      continue;
    }
    if (point.value >= releaseThreshold) {
      released = null;
      if (point.value > peak!.value) peak = point;
    } else {
      released ??= point.ms;
      // Require a 30 ms release. A short dip within one contact cannot
      // rearm the detector, and continuous pressure is a hold, not a tap.
      if (point.ms - released >= 30) {
        if (started != signal.first.ms && released - started <= maxContactMs) {
          peaks.add(peak!.ms);
        }
        started = released = null;
        peak = null;
      }
    }
  }
  return peaks;
}

typedef _ImpactPair = ({int adcIndex, int imuIndex});

List<_ImpactPair> _matchImpacts(
    List<int> adcPeaks, List<int> impacts, double toleranceMs,
    {bool allowExtraImuImpacts = false}) {
  const maxLagMs = 90;
  // The change-based impact detector can register extra unpaired motion.
  // Still require a strict majority of its impacts to rule out matching
  // every other event in a doubled cadence.
  final requiredImu = allowExtraImuImpacts
      ? impacts.length ~/ 2 + 1
      : (2 * impacts.length / 3).ceil();
  final required =
      math.max(3, math.max((2 * adcPeaks.length / 3).ceil(), requiredImu));
  if (required > math.min(adcPeaks.length, impacts.length)) return [];

  var best = <_ImpactPair>[];
  var bestError = double.infinity;
  // Test one shared lead or lag for the entire window. The residual allowance
  // covers timestamp quantization and small changes in the impact shape.
  for (var lag = -maxLagMs; lag <= maxLagMs; lag += 10) {
    var i = 0;
    var j = 0;
    var error = 0.0;
    final matched = <_ImpactPair>[];
    final offsets = <int>[];
    while (i < adcPeaks.length && j < impacts.length) {
      final offset = impacts[j] - adcPeaks[i];
      final residual = offset - lag;
      if (residual.abs() <= toleranceMs) {
        matched.add((adcIndex: i, imuIndex: j));
        offsets.add(offset);
        error += residual.abs();
        i++;
        j++;
      } else if (residual < 0) {
        j++;
      } else {
        i++;
      }
    }
    if (matched.length < required ||
        matched.length < best.length ||
        (matched.length == best.length && error >= bestError)) {
      continue;
    }
    offsets.sort();
    if (_quantile(offsets, 0.5).abs() > maxLagMs) continue;
    best = matched;
    bestError = error;
  }
  return best;
}

Iterable<({int first, int end})> _adcHighRuns(
  List<_Timed<double>> adc,
  double enterThreshold,
  double holdThreshold,
) sync* {
  const maxDipMs = 80;
  ({int first, int end})? pending;
  var bridgedMs = 0;
  // Restrict bridging to runs that spend at least two-thirds of their time
  // above the hold threshold.
  bool isSustained(({int first, int end}) run) =>
      3 * bridgedMs <= adc[run.end - 1].ms - adc[run.first].ms;

  for (final run in _aboveThreshold(adc, holdThreshold)) {
    if (pending != null) {
      final dipMs = adc[run.first].ms - adc[pending.end].ms;
      if (dipMs <= maxDipMs) {
        pending = (first: pending.first, end: run.end);
        bridgedMs += dipMs;
        continue;
      }
      if (isSustained(pending)) yield pending;
    }
    var first = run.first;
    while (first < run.end && adc[first].value < enterThreshold) {
      first++;
    }
    pending = first < run.end ? (first: first, end: run.end) : null;
    bridgedMs = 0;
  }
  if (pending != null && isSustained(pending)) yield pending;
}
