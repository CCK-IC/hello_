@TestOn('browser')
library;

import 'dart:async';

import 'package:ble_imu_visualizer/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

class _ChooserBle extends UniversalBlePlatform {
  final Completer<void> chooser = Completer<void>();

  @override
  Future<void> startScan(
          {ScanFilter? scanFilter, PlatformConfig? platformConfig}) =>
      chooser.future;

  @override
  Future<void> stopScan() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('browser chooser ends scanning as soon as a device is selected',
      (tester) async {
    final ble = _ChooserBle();
    UniversalBle.setInstance(ble);
    await tester.pumpWidget(const MaterialApp(home: BleImuApp()));

    await tester.tap(find.byIcon(Icons.search));
    await tester.pump();
    expect(
        tester.widget<IconButton>(find.byType(IconButton)).onPressed, isNull);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    ble.updateScanResult(BleDevice(deviceId: 'browser-token', name: 'Sensor'));
    ble.chooser.complete();
    await tester.pump();
    await tester.pump();

    expect(find.text('Sensor'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.widget<IconButton>(find.byType(IconButton)).onPressed,
        isNotNull);
    await tester.pumpWidget(const SizedBox());
  });
}
