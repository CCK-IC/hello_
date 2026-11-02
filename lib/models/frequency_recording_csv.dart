import 'frequency_history.dart';

/// Serialize frequency-analysis snapshots as one row per configured band.
///
/// Timestamps identify when an estimate (or gap marker) was generated, not
/// necessarily the last sample's timestamp. Empty peak fields mean an estimate
/// was unavailable, never that the measured frequency is 0.
String frequencyRecordingCsv(
  Iterable<FrequencyHistoryPoint> points, {
  required DateTime startedAt,
}) {
  final output = StringBuffer()
    ..writeln('estimate_time_utc,elapsed_ms,sensor,window_duration_ms,'
        'sample_count,sample_rate_hz,nyquist_hz,analysis_error,'
        'band,band_min_hz,band_max_hz,candidate_peak_hz,unavailable_reason');

  for (final point in points) {
    final analysis = point.analysis;
    final bands = analysis.bands.isEmpty ? [null] : analysis.bands;
    for (final band in bands) {
      final values = <Object?>[
        point.timestamp.toUtc().toIso8601String(),
        point.timestamp.difference(startedAt).inMicroseconds / 1000.0,
        point.sensor.name,
        analysis.duration.inMilliseconds,
        analysis.sampleCount,
        analysis.sampleRateHz,
        analysis.nyquistHz,
        analysis.error,
        band?.band.label,
        band?.band.minHz,
        band?.band.maxHz,
        band?.peakHz,
        band?.unavailableReason ?? analysis.error,
      ];
      output.writeln(values.map(_csvCell).join(','));
    }
  }
  return output.toString();
}

String _csvCell(Object? value) {
  if (value == null) return '';
  final text = value.toString();
  if (!text.contains(RegExp('[,"\\r\\n]'))) return text;
  return '"${text.replaceAll('"', '""')}"';
}
