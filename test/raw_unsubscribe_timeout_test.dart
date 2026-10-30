import 'dart:async';
import 'dart:typed_data';

import 'package:ble_imu_visualizer/main.dart';
import 'package:ble_imu_visualizer/models/protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

class _Ble extends UniversalBlePlatform {
  @override
  Future<void> startScan(
      {ScanFilter? scanFilter, PlatformConfig? platformConfig}) async {}
  @override
  Future<void> stopScan() async {}
  @override
  Future<void> connect(String deviceId,
      {Duration? connectionTimeout,
      bool autoConnect = false,
      ConnectionPlatformConfig? platformConfig}) async {
    updateConnection(deviceId, true);
  }

  @override
  Future<void> disconnect(String deviceId) async =>
      updateConnection(deviceId, false);
  @override
  Future<List<BleService>> discoverServices(
          String deviceId, bool withDescriptors,
          {DiscoverServicesPlatformConfig? platformConfig}) async =>
      [];
  @override
  Future<void> writeValue(
      String deviceId,
      String service,
      String characteristic,
      Uint8List value,
      BleOutputProperty bleOutputProperty) async {}
  @override
  Future<void> setNotifiable(String deviceId, String service,
      String characteristic, BleInputProperty bleInputProperty) async {
    if (characteristic.toLowerCase() == BleUuids.rawImuChar.toLowerCase() &&
        bleInputProperty == BleInputProperty.disabled) {
      throw TimeoutException('unsubscribe');
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
      'timed-out raw unsubscribe restores monitoring and blocks another change',
      (tester) async {
    final ble = _Ble();
    UniversalBle.setInstance(ble);
    await tester.pumpWidget(const MaterialApp(home: BleImuApp()));
    await tester.tap(find.byIcon(Icons.search));
    await tester.pump();
    ble.updateScanResult(BleDevice(deviceId: 'test-device', name: 'Sensor'));
    await tester.pump();
    await tester.tap(find.text('CONNECT'));
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 400));
    }
    final rawSwitch = find.widgetWithText(SwitchListTile, 'IMU raw');
    expect(rawSwitch, findsOneWidget);
    await tester.ensureVisible(rawSwitch);
    await tester.tap(rawSwitch);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final tile = tester.widget<SwitchListTile>(rawSwitch);
    expect(tile.value, isTrue);
    expect(tile.onChanged, isNull);
    await tester.drag(
        find.ancestor(of: rawSwitch, matching: find.byType(ListView)).first,
        const Offset(0, 1200));
    await tester.pump();
    expect(find.textContaining('subscription timed out'), findsOneWidget);
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(seconds: 11)));
    await tester.pump(const Duration(seconds: 1));
    expect(
        find.textContaining('Raw notifications have stopped'), findsOneWidget);
    expect(find.textContaining('subscription state is uncertain'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
