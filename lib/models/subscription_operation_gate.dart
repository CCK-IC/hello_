/// Tracks in-flight subscription changes for the current BLE connection.
///
/// A timed-out operation may still be running in the native BLE stack. Block
/// further changes to that characteristic until the connection is reset.
class SubscriptionOperationGate {
  final Map<String, Object> _pending = {};
  final Set<String> _uncertain = {};

  bool canStart(String key) =>
      !_pending.containsKey(key) && !_uncertain.contains(key);

  Object? begin(String key) {
    if (!canStart(key)) return null;
    final token = Object();
    _pending[key] = token;
    return token;
  }

  /// Returns false if the operation belongs to an earlier connection.
  bool finish(String key, Object token, {bool timedOut = false}) {
    if (!identical(_pending[key], token)) return false;
    _pending.remove(key);
    if (timedOut) _uncertain.add(key);
    return true;
  }

  void reset() {
    _pending.clear();
    _uncertain.clear();
  }
}
