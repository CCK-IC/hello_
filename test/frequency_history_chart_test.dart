import 'package:ble_imu_visualizer/models/frequency_history.dart';
import 'package:ble_imu_visualizer/models/imu_frequency_analysis.dart';
import 'package:ble_imu_visualizer/models/raw_imu_history.dart';
import 'package:ble_imu_visualizer/widgets/frequency_history_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

FrequencyHistoryPoint point(int second,
    {double? peak = 2,
    double max = 5,
    RawSensorType sensor = RawSensorType.accelerometer}) {
  return FrequencyHistoryPoint(
    timestamp: DateTime(2026).add(Duration(seconds: second)),
    sensor: sensor,
    analysis: ImuFrequencyAnalysis(
      error: null,
      sampleRateHz: 25,
      nyquistHz: 12.5,
      duration: const Duration(seconds: 8),
      sampleCount: 200,
      bands: [
        FrequencyBandResult(FrequencyBand('Percussion band', 1, max), peak,
            peak == null ? 'No peak' : null),
        const FrequencyBandResult(
            FrequencyBand('Vibration band', 6.5, 10), null, 'Unavailable'),
      ],
    ),
  );
}

void main() {
  test('history retention and point cap keep the latest measurements', () {
    final history =
        FrequencyHistory(retention: const Duration(seconds: 3), maxPoints: 3);
    for (var i = 0; i <= 5; i++) {
      history.add(point(i));
    }
    expect(history.points.map((p) => p.timestamp.second), [3, 4, 5]);
    history.setRetention(const Duration(seconds: 1),
        DateTime(2026).add(const Duration(seconds: 5)));
    expect(history.points.map((p) => p.timestamp.second), [4, 5]);
  });

  test('segments break on missing data, time gaps and configuration changes',
      () {
    final points = [
      point(0),
      point(1),
      point(2, peak: null),
      point(3),
      point(6),
      point(7, max: 4),
      point(8, max: 4, sensor: RawSensorType.gyroscope)
    ];
    final segments = frequencyPlotSegments(points, FrequencySeries.percussion);
    expect(segments.map((s) => s.length), [2, 1, 1, 1, 1]);
    expect(frequencyPlotSegments(points, FrequencySeries.vibration), isEmpty);
  });

  testWidgets('chart handles empty selection and missing estimates',
      (tester) async {
    final now = DateTime(2026).add(const Duration(seconds: 10));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: FrequencyHistoryChart(
                history: [point(9)],
                visiblePeriod: const Duration(seconds: 10),
                selected: const {},
                now: now))));
    expect(find.text('Select a frequency band to display.'), findsOneWidget);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: FrequencyHistoryChart(
                history: [point(9)],
                visiblePeriod: const Duration(seconds: 10),
                selected: const {FrequencySeries.vibration},
                now: now))));
    expect(find.text('Waiting for frequency estimates...'), findsOneWidget);
  });

  testWidgets('chart describes the visible window and selected series',
      (tester) async {
    final now = DateTime(2026).add(const Duration(seconds: 10));
    const seed = Color(0xFF0D6F73);
    await tester.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(
        colorScheme:
            ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(2)),
        child: child!,
      ),
      home: Scaffold(
        body: FrequencyHistoryChart(
          history: [point(3, peak: 5), point(8, peak: 2), point(9, peak: null)],
          visiblePeriod: const Duration(seconds: 5),
          selected: FrequencySeries.values.toSet(),
          now: now,
        ),
      ),
    ));

    final summary = find.bySemanticsLabel(RegExp(r'^Frequency history over'));
    expect(
      tester.getSemantics(summary),
      containsSemantics(
        isImage: true,
        label: 'Frequency history over the last 5 seconds. '
            'The frequency axis runs from 0 Hz to 2.2 Hz. '
            'The latest plotted peak for Percussion band was 2.00 Hz, 2 seconds ago. '
            'Vibration band has no estimate in this window. '
            'Gaps mark missing estimates or changes in sensor or band settings.',
      ),
    );
    expect(find.text('2.2 Hz'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
