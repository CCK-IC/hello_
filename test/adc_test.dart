import 'dart:typed_data';
import 'package:ble_imu_visualizer/models/adc_history.dart';
import 'package:ble_imu_visualizer/widgets/adc_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'batch_test_fixtures.dart';

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
  test(
      'v3 history expands only local slots, preserves arrival and sensor spacing',
      () {
    final history = AdcHistory(maxSamples: 5);
    final arrival = DateTime.utc(2026);
    expect(
        history.addPacket(sensorFrame(kind: 3, mask: 3), receivedAt: arrival),
        isTrue);
    expect(history.points.length, 3);
    expect(history.points.map((p) => p.sample.gloveId), [0, 0, 0]);
    expect(
        history.points.map((p) => p.receivedAt), [arrival, arrival, arrival]);
    expect(
        history.points
            .map((p) => p.sampledAt.difference(arrival).inMilliseconds),
        [-40, -20, 0]);
    expect(
        history
            .pointsSince(arrival.subtract(const Duration(milliseconds: 20)))
            .length,
        2);
    final malformed = sensorFrame(kind: 3)..[28 + 4 * 20 + 10] = 1;
    expect(history.addPacket(malformed, receivedAt: arrival), isFalse);
    expect(history.points.length, 3);
    history.addPacket(sensorFrame(kind: 3, sequence: 1, timestamp: 44),
        receivedAt: arrival.add(const Duration(seconds: 2)));
    expect(history.points.length, 5);
    expect(history.points.last.sampledAt,
        arrival.add(const Duration(milliseconds: 60)));
    expect(history.points.last.receivedAt,
        arrival.add(const Duration(seconds: 2)));
    history.clear();
    final later = arrival.add(const Duration(seconds: 10));
    history.addPacket(sensorFrame(kind: 3, rows: 1, timestamp: 7),
        receivedAt: later);
    expect(history.points.single.sampledAt, later);
  });

  test('legacy AUX singleton fields and history-point timestamp fallback', () {
    final sample = AdcSample.decodeAll(packet(7, List.filled(8, 1)))!.single;
    expect(sample.version, 1);
    expect(sample.gloveId, 0);
    expect(sample.activeChannelCount, 8);
    expect(sample.sampleValid, isTrue);
    final now = DateTime.utc(2026);
    expect(AdcHistoryPoint(now, sample).sampledAt, now);
  });

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
    expect(
        history
            .pointsSince(start.add(const Duration(seconds: 1)))
            .map((point) => point.sample.sequence),
        [1, 2]);
    expect(
        history
            .pointsSince(start.add(const Duration(seconds: 10)))
            .map((point) => point.sample.sequence),
        [2]);
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
