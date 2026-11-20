import 'package:ble_imu_visualizer/models/sample_timeline.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026);
  test(
      'first batch last timestamp anchors to arrival; subsequent bursts use sensor deltas',
      () {
    final timeline = SampleTimeline();
    final first = timeline.mapBatch([1000, 1020, 1055], now);
    expect(first.map((t) => t.difference(now).inMilliseconds), [-55, -35, 0]);
    final second =
        timeline.mapBatch([1070, 1100], now.add(const Duration(seconds: 2)));
    expect(second.map((t) => t.difference(now).inMilliseconds), [15, 45]);
  });
  test('u32 rollover works inside a batch and across notifications', () {
    final timeline = SampleTimeline();
    expect(
        timeline.mapBatch(
            [0xfffffff0, 4], now).map((t) => t.difference(now).inMilliseconds),
        [-20, 0]);
    expect(
        timeline.mapBatch(
            [24, 44], now).map((t) => t.difference(now).inMilliseconds),
        [20, 40]);
    timeline.reset();
    timeline.mapBatch([0xfffffff0], now);
    expect(
        timeline.mapBatch(
            [4, 24], now).map((t) => t.difference(now).inMilliseconds),
        [20, 40]);
  });
  test('equal timestamps stay equal; empty input does not move the anchor', () {
    final timeline = SampleTimeline();
    expect(timeline.mapBatch([], now), isEmpty);
    expect(timeline.mapBatch([10, 10, 10], now), [now, now, now]);
    expect(
        timeline.mapBatch([], now.add(const Duration(seconds: 10))), isEmpty);
    expect(timeline.mapBatch([20], now).single,
        now.add(const Duration(milliseconds: 10)));
  });
  test(
      'reset and device clock restart reanchor without fabricating a huge leap',
      () {
    final timeline = SampleTimeline();
    timeline.mapBatch([1000, 1020], now);
    final later = now.add(const Duration(seconds: 10));
    expect(
        timeline.mapBatch(
            [5, 25], later).map((t) => t.difference(later).inMilliseconds),
        [-20, 0]);
    timeline.reset();
    expect(timeline.mapBatch([500], later).single, later);
  });
  test('invalid intra-batch chronology is rejected without changing timeline',
      () {
    final timeline = SampleTimeline();
    timeline.mapBatch([100], now);
    expect(() => timeline.mapBatch([120, 110], now), throwsArgumentError);
    expect(timeline.mapBatch([130], now).single,
        now.add(const Duration(milliseconds: 30)));
  });
}
