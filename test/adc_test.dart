import 'dart:typed_data';
import 'package:ble_imu_visualizer/models/adc_history.dart';
import 'package:ble_imu_visualizer/widgets/adc_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List packet(int sequence, List<int> channels) {
  final data = ByteData(22)
    ..setUint8(0, 1)
    ..setUint8(1, sequence)
    ..setUint32(2, 0x12345678, Endian.little);
  for (var i = 0; i < 8; i++) {
    data.setInt16(6 + 2 * i, channels[i], Endian.little);
  }
  return data.buffer.asUint8List();
}

void main() {
  test('decodes firmware layout, including signed channels and byte offsets',
      () {
    final bytes = packet(0x23, [-1, 0, 1, 255, 256, 4095, -32768, 32767]);
    final sample = AdcSample.decode(bytes)!;
    expect(sample.sequence, 0x23);
    expect(sample.timestampMs, 0x12345678);
    expect(sample.channels, [-1, 0, 1, 255, 256, 4095, -32768, 32767]);
    expect(() => sample.channels[0] = 2, throwsUnsupportedError);
    expect(AdcSample.decode(bytes.sublist(0, 21)), isNull);
    expect(AdcSample.decode(Uint8List(23)), isNull);
    bytes[0] = 2;
    expect(AdcSample.decode(bytes), isNull);
  });

  test('history rejects bad packets and retains newest samples', () {
    final history = AdcHistory(maxSamples: 2);
    expect(history.addPacket(Uint8List(0)), isFalse);
    for (var i = 0; i < 3; i++) {
      expect(history.addPacket(packet(i, List.filled(8, i))), isTrue);
    }
    expect(history.points.map((p) => p.sample.sequence), [1, 2]);
    history.maxSamples = 1;
    expect(history.points.map((p) => p.sample.sequence), [2]);
    expect(() => history.maxSamples = 0, throwsArgumentError);
    history.clear();
    expect(history.points, isEmpty);
  });

  test('visible window keeps recent points and the latest stale reading', () {
    final history = AdcHistory();
    final start = DateTime.utc(2026);
    for (var i = 0; i < 3; i++) {
      history.addPacket(packet(i, List.filled(8, i)),
          receivedAt: start.add(Duration(seconds: i)));
    }
    expect(history.pointsSince(start.add(const Duration(seconds: 1)))
        .map((point) => point.sample.sequence), [1, 2]);
    expect(history.pointsSince(start.add(const Duration(seconds: 10)))
        .map((point) => point.sample.sequence), [2]);
  });

  testWidgets('shows waiting state, latest values, and channel controls',
      (tester) async {
    final history = AdcHistory();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: AdcChart(history: history.points)))));
    expect(find.text('Waiting for auxiliary ADC data...'), findsOneWidget);
    history.addPacket(packet(4, [10, 20, 30, 40, 50, 60, 70, 80]));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: AdcChart(history: history.points)))));
    expect(find.text('CH1: 10'), findsOneWidget);
    expect(find.text('CH8: 80'), findsOneWidget);
    expect(find.textContaining('Sequence 4'), findsOneWidget);
    await tester.tap(find.text('CH1: 10'));
    await tester.pump();
    expect(
        tester
            .widget<FilterChip>(find.ancestor(
                of: find.text('CH1: 10'), matching: find.byType(FilterChip)))
            .selected,
        isFalse);
    expect(tester.takeException(), isNull);
  });
}
