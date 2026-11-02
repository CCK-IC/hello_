import 'dart:async';
import 'dart:math' as math;

import 'package:ble_imu_visualizer/models/protocol.dart';
import 'package:ble_imu_visualizer/models/raw_imu_history.dart';
import 'package:ble_imu_visualizer/widgets/imu_analysis_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

RawImuHistoryPoint sample(int index, DateTime start) {
  final value = (1000 * math.sin(2 * math.pi * 2 * index / 25)).round();
  return RawImuHistoryPoint(
    receivedAt: start.add(Duration(milliseconds: index * 40)),
    sample: RawImuSample(
      version: 1,
      flags: const RawImuFlags(7, 1),
      accelerometerRangeCode: 0,
      gyroscopeRangeCode: 0,
      sequence: index,
      timestampMs: index * 40,
      accelerometerX: value,
      accelerometerY: 0,
      accelerometerZ: 16384,
      gyroscopeX: 0,
      gyroscopeY: 0,
      gyroscopeZ: 0,
    ),
  );
}

void main() {
  testWidgets(
      'live analysis clears estimates when data stops or session resets',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final samples = StreamController<RawImuHistoryPoint?>(sync: true);
    var now = DateTime(2026, 1, 1);
    await tester.pumpWidget(MaterialApp(
      home: ImuAnalysisPage(samples: samples.stream, clock: () => now),
    ));
    expect(
        find.text('Waiting for raw IMU data from this glove.'), findsOneWidget);

    final start = now;
    for (var i = 0; i < 151; i++) {
      samples.add(sample(i, start));
    }
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Observed sample rate: 25.0 Hz'), findsOneWidget);
    expect(find.text('1.99 Hz candidate'), findsOneWidget);

    now = now.add(const Duration(seconds: 4));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Raw IMU data stopped. Waiting for fresh samples.'),
        findsOneWidget);
    expect(find.text('1.99 Hz candidate'), findsNothing);

    samples.add(null);
    await tester.pump();
    expect(
        find.text('Waiting for raw IMU data from this glove.'), findsOneWidget);
    expect(find.text('1.99 Hz candidate'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    unawaited(samples.close());
  });

  testWidgets('invalid bands are rejected and signal can be changed',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final samples = StreamController<RawImuHistoryPoint?>(sync: true);
    await tester.pumpWidget(
        MaterialApp(home: ImuAnalysisPage(samples: samples.stream)));
    await tester.enterText(
        find.widgetWithText(TextField, 'Percussion max'), '0');
    await tester.tap(find.text('Apply bands'));
    await tester.pump();
    expect(
        find.textContaining('Enter positive frequency ranges'), findsOneWidget);
    await tester.tap(find.text('Angular velocity'));
    await tester.pump();
    expect(find.text('Angular velocity'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    unawaited(samples.close());
  });

  testWidgets('controls fit a narrow phone screen', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final samples = StreamController<RawImuHistoryPoint?>(sync: true);
    await tester.pumpWidget(
        MaterialApp(home: ImuAnalysisPage(samples: samples.stream)));
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    unawaited(samples.close());
  });
}
