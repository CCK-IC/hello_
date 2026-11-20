import 'dart:typed_data';

import 'package:ble_imu_visualizer/models/adc_history.dart';
import 'package:ble_imu_visualizer/models/protocol.dart';
import 'package:ble_imu_visualizer/models/raw_imu_history.dart';
import 'package:ble_imu_visualizer/widgets/adc_chart.dart';
import 'package:ble_imu_visualizer/widgets/raw_imu_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _PathCanvas extends Fake implements Canvas {
  final paths = <Path>[];

  @override
  void drawPath(Path path, Paint paint) => paths.add(Path.from(path));

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

RawImuSample _raw(int sequence) {
  final bytes = ByteData(20)
    ..setUint8(0, 2)
    ..setUint8(1, 7)
    ..setUint16(2, sequence, Endian.little)
    ..setInt16(8, sequence, Endian.little);
  return RawImuSample.decode(bytes.buffer.asUint8List())!;
}

AdcSample _adc(int sequence) {
  final bytes = ByteData(22)
    ..setUint8(0, 1)
    ..setUint8(1, sequence)
    ..setInt16(6, sequence, Endian.little);
  return AdcSample.decode(bytes.buffer.asUint8List())!;
}

double _horizontalSpan(Path path) {
  final metric = path.computeMetrics().single;
  return metric.getTangentForOffset(metric.length)!.position.dx -
      metric.getTangentForOffset(0)!.position.dx;
}

void main() {
  testWidgets('raw chart windows and X positions use sampledAt',
      (tester) async {
    final now = DateTime.now();
    final callback = now.subtract(const Duration(minutes: 1));
    final points = [
      for (var i = 0; i < 2; i++)
        RawImuHistoryPoint(
          receivedAt: callback,
          sample: _raw(i + 1),
          sampleTime: now.subtract(Duration(seconds: 4 - i)),
        ),
      // A recent callback cannot put an old acquisition into this window.
      RawImuHistoryPoint(
        receivedAt: now,
        sample: _raw(3),
        sampleTime: now.subtract(const Duration(seconds: 30)),
      ),
    ];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RawImuChart(
          history: points,
          sensor: RawSensorType.accelerometer,
          visiblePeriod: const Duration(seconds: 10),
        ),
      ),
    ));
    final paint = tester.widget<CustomPaint>(find.descendant(
      of: find.byType(RawImuChart),
      matching: find.byType(CustomPaint),
    ));
    final canvas = _PathCanvas();
    paint.painter!.paint(canvas, const Size(700, 240));
    expect(canvas.paths, hasLength(3));
    // Plot width is 700 - 62 - 8; sensor times differ by 1s in a 10s window.
    expect(_horizontalSpan(canvas.paths.first), closeTo(63, 0.01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('raw chart separates retained device sessions', (tester) async {
    final now = DateTime.now();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RawImuChart(
          history: [
            for (var i = 0; i < 4; i++)
              RawImuHistoryPoint(
                receivedAt: now,
                sampleTime: now.subtract(Duration(seconds: 5 - i)),
                sample: _raw(i + 1),
                deviceId: 'device',
                sessionId: i ~/ 2,
              ),
          ],
          sensor: RawSensorType.accelerometer,
          visiblePeriod: const Duration(seconds: 10),
        ),
      ),
    ));
    final paint = tester.widget<CustomPaint>(find.descendant(
      of: find.byType(RawImuChart),
      matching: find.byType(CustomPaint),
    ));
    final canvas = _PathCanvas();
    paint.painter!.paint(canvas, const Size(700, 240));
    expect(canvas.paths.first.computeMetrics().length, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ADC chart windows and X positions use sampledAt',
      (tester) async {
    final now = DateTime.now();
    final callback = now.subtract(const Duration(minutes: 1));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AdcChart(
          history: [
            for (var i = 0; i < 2; i++)
              AdcHistoryPoint(callback, _adc(i + 1),
                  sampleTime: now.subtract(Duration(seconds: 4 - i))),
            AdcHistoryPoint(now, _adc(3),
                sampleTime: now.subtract(const Duration(seconds: 30))),
          ],
          visiblePeriod: const Duration(seconds: 10),
        ),
      ),
    ));
    final paint = tester.widget<CustomPaint>(find
        .descendant(
          of: find.byType(AdcChart),
          matching: find.byType(CustomPaint),
        )
        .last);
    final canvas = _PathCanvas();
    paint.painter!.paint(canvas, const Size(700, 220));
    expect(canvas.paths, hasLength(8));
    // Plot width is 700 - 58 - 8.
    expect(_horizontalSpan(canvas.paths.first), closeTo(63.4, 0.01));
    expect(tester.takeException(), isNull);
  });
}
