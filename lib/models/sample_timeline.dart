/// Maps one device/session's u32 sensor clock to chart time. Arrival timestamps
/// remain separate. Call reset at connection/subscription boundaries.
class SampleTimeline {
  int? _lastTimestamp;
  DateTime? _lastTime;

  void reset() {
    _lastTimestamp = null;
    _lastTime = null;
  }

  List<DateTime> mapBatch(List<int> timestampsMs, DateTime receivedAt) {
    if (timestampsMs.isEmpty) return [];
    final raw = [for (final timestamp in timestampsMs) timestamp & 0xffffffff];
    // A backward jump is a new sensor epoch, not a 49-day forward leap.
    var previous = _lastTimestamp;
    var restart = previous == null;
    for (final timestamp in raw) {
      if (previous != null &&
          ((timestamp - previous) & 0xffffffff) >= 0x80000000) {
        restart = true;
      }
      previous = timestamp;
    }
    final result = <DateTime>[];
    if (restart) {
      // Anchor the newest epoch in this batch at the actual callback time.
      // Valid wire batches are nondecreasing; no fixed-rate interpolation.
      var end = receivedAt;
      result.add(end);
      for (var i = raw.length - 2; i >= 0; i--) {
        final delta = (raw[i + 1] - raw[i]) & 0xffffffff;
        if (delta >= 0x80000000) {
          throw ArgumentError('Batch timestamps must be chronological');
        }
        end = end.subtract(Duration(milliseconds: delta));
        result.add(end);
      }
      final chronological = result.reversed.toList();
      _lastTimestamp = raw.last;
      _lastTime = chronological.last;
      return chronological;
    }
    var time = _lastTime!;
    var last = _lastTimestamp!;
    for (final timestamp in raw) {
      time = time.add(Duration(milliseconds: (timestamp - last) & 0xffffffff));
      result.add(time);
      last = timestamp;
    }
    _lastTimestamp = last;
    _lastTime = time;
    return result;
  }
}
