import 'package:ble_imu_visualizer/models/raw_stream_watchdog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only reports a stall after monitoring starts and grace period expires', () {
    final watch = RawStreamWatchdog();
    final start = DateTime.utc(2026);
    expect(watch.isStalled(start.add(const Duration(days: 1))), isFalse);
    watch.start(start);
    expect(watch.isStalled(start.add(const Duration(seconds: 9))), isFalse);
    expect(watch.isStalled(start.add(const Duration(seconds: 10))), isTrue);
  });

  test('activity clears a stall and stopping prevents further alerts', () {
    final watch = RawStreamWatchdog();
    final start = DateTime.utc(2026);
    watch.start(start);
    final activity = start.add(const Duration(seconds: 15));
    expect(watch.isStalled(activity), isTrue);
    watch.recordActivity(activity);
    expect(watch.isStalled(activity), isFalse);
    expect(watch.isStalled(activity.add(const Duration(seconds: 10))), isTrue);
    watch.stop();
    watch.recordActivity(activity.add(const Duration(seconds: 20)));
    expect(watch.isStalled(activity.add(const Duration(days: 1))), isFalse);
  });
}
