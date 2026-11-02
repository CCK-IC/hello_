import 'dart:collection';

import 'imu_frequency_analysis.dart';
import 'raw_imu_history.dart';

/// A snapshot of one rolling-window estimate, including its configuration.
class FrequencyHistoryPoint {
  final DateTime timestamp;
  final RawSensorType sensor;
  final ImuFrequencyAnalysis analysis;

  FrequencyHistoryPoint({
    required this.timestamp,
    required this.sensor,
    required ImuFrequencyAnalysis analysis,
  }) : analysis = ImuFrequencyAnalysis(
          error: analysis.error,
          sampleRateHz: analysis.sampleRateHz,
          nyquistHz: analysis.nyquistHz,
          duration: analysis.duration,
          sampleCount: analysis.sampleCount,
          bands: List.unmodifiable(analysis.bands),
        );
}

/// Time-bounded, chronological frequency estimates for the current session.
class FrequencyHistory {
  FrequencyHistory(
      {Duration retention = const Duration(minutes: 10), this.maxPoints = 3600})
      : assert(retention > Duration.zero),
        assert(maxPoints > 0),
        _retention = retention;

  Duration _retention;
  final int maxPoints;
  final List<FrequencyHistoryPoint> _points = [];

  Duration get retention => _retention;
  UnmodifiableListView<FrequencyHistoryPoint> get points =>
      UnmodifiableListView(_points);

  void setRetention(Duration value, DateTime now) {
    if (value <= Duration.zero) throw ArgumentError.value(value, 'retention');
    _retention = value;
    prune(now);
  }

  void add(FrequencyHistoryPoint point) {
    if (_points.isNotEmpty &&
        point.timestamp.isBefore(_points.last.timestamp)) {
      throw ArgumentError('Frequency history timestamps must be chronological');
    }
    _points.add(point);
    prune(point.timestamp);
    if (_points.length > maxPoints) {
      _points.removeRange(0, _points.length - maxPoints);
    }
  }

  void prune(DateTime now) {
    final cutoff = now.subtract(_retention);
    var count = 0;
    while (
        count < _points.length && _points[count].timestamp.isBefore(cutoff)) {
      count++;
    }
    if (count > 0) _points.removeRange(0, count);
  }

  void clear() => _points.clear();
}
