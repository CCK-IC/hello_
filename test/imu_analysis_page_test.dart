import 'dart:async';
import 'dart:convert';
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
  testWidgets('initial band controls match the analysis defaults',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final samples = StreamController<RawImuHistoryPoint?>(sync: true);
    await tester.pumpWidget(
        MaterialApp(home: ImuAnalysisPage(samples: samples.stream)));
    for (final entry in {
      'Percussion min': 1.0,
      'Percussion max': 5.0,
      'Vibration min': 6.5,
      'Vibration max': 10.0,
    }.entries) {
      final field =
          tester.widget<TextField>(find.widgetWithText(TextField, entry.key));
      expect(double.parse(field.controller!.text), entry.value);
    }
    await tester.pumpWidget(const SizedBox());
    unawaited(samples.close());
  });

  testWidgets('frequency results use two columns and stack on narrow screens',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final samples = StreamController<RawImuHistoryPoint?>(sync: true);
    await tester.pumpWidget(
        MaterialApp(home: ImuAnalysisPage(samples: samples.stream)));
    final first = find.byKey(const ValueKey('frequency-result-0'));
    final second = find.byKey(const ValueKey('frequency-result-1'));
    expect(tester.getTopLeft(first).dy, tester.getTopLeft(second).dy);
    expect(
        tester.getTopLeft(second).dx, greaterThan(tester.getTopLeft(first).dx));

    await tester.binding.setSurfaceSize(const Size(320, 900));
    await tester.pump();
    expect(
        tester.getTopLeft(second).dy, greaterThan(tester.getTopLeft(first).dy));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    unawaited(samples.close());
  });

  testWidgets('timed recording saves automatically and keeps a retry copy',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final samples = StreamController<RawImuHistoryPoint?>(sync: true);
    final exports = <String>[];
    var now = DateTime(2026, 1, 1);
    final start = now;
    await tester.pumpWidget(MaterialApp(
      home: ImuAnalysisPage(
        samples: samples.stream,
        clock: () => now,
        saveCsv: (csv, _, __) async => exports.add(csv),
      ),
    ));
    for (var i = 0; i < 151; i++) {
      samples.add(sample(i, start));
    }
    await tester.pump(const Duration(seconds: 1));
    await tester.scrollUntilVisible(find.text('Record CSV'), 300,
        scrollable: find.byType(Scrollable).last);
    await tester.tap(find.text('10 seconds').last);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await tester.tap(find.text('5 seconds').last);
    await tester.pump();
    await tester.tap(find.text('Record CSV'));
    await tester.pump();
    for (var second = 1; second <= 5; second++) {
      for (var i = 0; i < 25; i++) {
        samples.add(sample(150 + (second - 1) * 25 + i + 1, start));
      }
      now = now.add(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.pump();
    expect(exports, hasLength(1));
    expect(find.text('Save recording CSV'), findsOneWidget);
    expect(const LineSplitter().convert(exports.single).length, greaterThan(1));
    await tester.pumpWidget(const SizedBox());
    unawaited(samples.close());
  });

  testWidgets('disconnect preserves a partial recording with a gap',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final samples = StreamController<RawImuHistoryPoint?>(sync: true);
    final exports = <String>[];
    var now = DateTime(2026, 1, 1);
    final start = now;
    await tester.pumpWidget(MaterialApp(
      home: ImuAnalysisPage(
        samples: samples.stream,
        clock: () => now,
        saveCsv: (csv, _, __) async => exports.add(csv),
      ),
    ));
    for (var i = 0; i < 151; i++) {
      samples.add(sample(i, start));
    }
    await tester.pump(const Duration(seconds: 1));
    await tester.scrollUntilVisible(find.text('Record CSV'), 300,
        scrollable: find.byType(Scrollable).last);
    await tester.tap(find.text('Record CSV'));
    await tester.pump();
    samples.add(sample(151, start));
    now = now.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    samples.add(null);
    await tester.pump();
    expect(find.text('Save recording CSV'), findsOneWidget);
    await tester.tap(find.text('Save recording CSV'));
    await tester.pump();
    expect(exports.single, contains('Connection ended.'));
    expect(const LineSplitter().convert(exports.single), hasLength(5));
    await tester.pumpWidget(const SizedBox());
    unawaited(samples.close());
  });

  testWidgets('records new frequency estimates and exports their metadata',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final samples = StreamController<RawImuHistoryPoint?>(sync: true);
    final exports = <String>[];
    var now = DateTime(2026, 1, 1);
    final start = now;
    await tester.pumpWidget(MaterialApp(
      home: ImuAnalysisPage(
        samples: samples.stream,
        clock: () => now,
        saveCsv: (csv, _, __) async => exports.add(csv),
      ),
    ));
    for (var i = 0; i < 151; i++) {
      samples.add(sample(i, start));
    }
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.scrollUntilVisible(find.text('Record CSV'), 300,
        scrollable: find.byType(Scrollable).last);
    await tester.tap(find.text('Record CSV'));
    await tester.pump();
    for (var i = 151; i < 176; i++) {
      samples.add(sample(i, start));
    }
    now = now.add(const Duration(seconds: 1));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Recording 1 estimates…'), findsOneWidget);

    // Rebuilding without another raw packet must not duplicate an estimate.
    now = now.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Recording 1 estimates…'), findsOneWidget);
    await tester.tap(find.text('Stop and save'));
    await tester.pump();
    expect(exports, hasLength(1));
    final rows = const LineSplitter().convert(exports.single);
    expect(rows, hasLength(3)); // header plus one row per band
    expect(rows.first, contains('estimate_time_utc'));
    expect(rows[1], contains('accelerometer'));
    expect(rows[1], contains('Percussion band'));
    expect(rows[1], contains('Percussion band,1.0,5.0,'));
    expect(rows[2], contains('Vibration band,6.5,10.0,'));
    await tester.pumpWidget(const SizedBox());
    unawaited(samples.close());
  });

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
    expect(find.textContaining(RegExp(r'^(1\.9\d|2\.0\d) Hz$')), findsOneWidget);

    now = now.add(const Duration(seconds: 4));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Raw IMU data stopped. Waiting for fresh samples.'),
        findsOneWidget);
    expect(find.textContaining(RegExp(r'^(1\.9\d|2\.0\d) Hz$')), findsNothing);

    samples.add(null);
    await tester.pump();
    expect(
        find.text('Waiting for raw IMU data from this glove.'), findsOneWidget);
    expect(find.textContaining(RegExp(r'^(1\.9\d|2\.0\d) Hz$')), findsNothing);
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
