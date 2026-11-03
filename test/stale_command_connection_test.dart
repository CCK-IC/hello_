import 'dart:async';
import 'dart:typed_data';

import 'package:ble_imu_visualizer/main.dart';
import 'package:ble_imu_visualizer/widgets/control_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

const _deviceId = 'aa:bb:cc:dd:ee:ff';

class _DelayedModeBle extends UniversalBlePlatform {
  final modeWrite = Completer<void>();
  final writes = <int>[];
  bool connected = false;

  @override
  Future<void> startScan(
      {ScanFilter? scanFilter, PlatformConfig? platformConfig}) async {}

  @override
  Future<void> stopScan() async {}

  @override
  Future<void> connect(String deviceId,
      {bool autoConnect = false,
      Duration? connectionTimeout,
      ConnectionPlatformConfig? platformConfig}) async {
    connected = true;
    updateConnection(deviceId, true);
  }

  @override
  Future<void> disconnect(String deviceId) async {
    connected = false;
    updateConnection(deviceId, false);
  }

  @override
  Future<BleConnectionState> getConnectionState(String deviceId) async =>
      connected
          ? BleConnectionState.connected
          : BleConnectionState.disconnected;

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
      BleOutputProperty property) async {
    writes.add(value.first);
    if (value.first == 0x04) await modeWrite.future;
  }

  @override
  Future<void> setNotifiable(String deviceId, String service,
      String characteristic, BleInputProperty property) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
      'an old slow-mode write cannot restore a rate after reconnect begins',
      (tester) async {
    final ble = _DelayedModeBle();
    UniversalBle.setInstance(ble);
    await tester.binding.setSurfaceSize(const Size(1200, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(home: BleImuApp()));

    await tester.tap(find.byIcon(Icons.search));
    await tester.pump();
    ble.updateScanResult(BleDevice(deviceId: _deviceId, name: 'Test IMU'));
    await tester.pump();
    await tester.tap(find.text('CONNECT'));
    await tester.pumpAndSettle();
    expect(ble.writes.where((value) => value == 0x01), hasLength(1));

    await tester.scrollUntilVisible(find.text('Slow/Debug Mode (0x04)'), 400,
        scrollable: find.byType(Scrollable).last);
    final slowSwitch = find.descendant(
        of: find.byType(ControlPanel), matching: find.byType(Switch));
    tester.widget<Switch>(slowSwitch).onChanged!(true);
    await tester.pump();
    expect(ble.writes.last, 0x04);

    // Lose the first connection while the mode write is still in flight.
    ble.connected = false;
    ble.updateConnection(_deviceId, false);
    await tester.pump();
    await tester.tap(find.text('CONNECT'));
    await tester.pump();
    ble.modeWrite.complete();
    await tester.pumpAndSettle();

    // Only the normal setup write for each connection is allowed; the stale
    // mode operation must not issue a third rate write into the new session.
    expect(ble.writes.where((value) => value == 0x01), hasLength(2));
    expect(ble.writes.where((value) => value == 0x04), hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
