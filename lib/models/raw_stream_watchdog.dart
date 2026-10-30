/// Tracks notification activity only while a raw stream is expected.
class RawStreamWatchdog {
  RawStreamWatchdog({this.timeout = const Duration(seconds: 10)});

  final Duration timeout;
  DateTime? _lastActivity;

  void start(DateTime now) => _lastActivity = now;
  void stop() => _lastActivity = null;

  void recordActivity(DateTime now) {
    if (_lastActivity != null) _lastActivity = now;
  }

  bool isStalled(DateTime now) =>
      _lastActivity != null && now.difference(_lastActivity!) >= timeout;
}
