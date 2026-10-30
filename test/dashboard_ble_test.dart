import 'dart:typed_data';

import 'package:ble_imu_visualizer/main.dart';
import 'package:ble_imu_visualizer/models/protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

const _deviceId = 'aa:bb:cc:dd:ee:ff';

class _FakeBlePlatform extends UniversalBlePlatform {
  bool connected = false;
  final subscriptions = <String>[];

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
      BleOutputProperty bleOutputProperty) async {}

  @override
  Future<void> setNotifiable(String deviceId, String service,
      String characteristic, BleInputProperty bleInputProperty) async {
    subscriptions.add('$service/$characteristic/$bleInputProperty');
  }

  @override
  Future<int> requestMtu(String deviceId, int expectedMtu) async => expectedMtu;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Uint8List _auxPacket(int sequence, List<int> channels) {
  final data = ByteData(22)
    ..setUint8(0, 1)
    ..setUint8(1, sequence)
    ..setUint32(2, 1234, Endian.little);
  for (var i = 0; i < channels.length; i++) {
    data.setInt16(6 + 2 * i, channels[i], Endian.little);
  }
  return data.buffer.asUint8List();
}

void main() {
  testWidgets(
      'dashboard receives AUX notifications and clears them on reconnect',
      (tester) async {
    final ble = _FakeBlePlatform();
    UniversalBle.setInstance(ble);
    await tester.pumpWidget(const MaterialApp(home: BleImuApp()));

    await tester.tap(find.byIcon(Icons.search));
    await tester.pump();
    ble.updateScanResult(BleDevice(deviceId: _deviceId, name: 'Test IMU'));
    await tester.pump();
    expect(find.text('Test IMU'), findsOneWidget);
    await tester.tap(find.text('CONNECT'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.link_off), findsOneWidget);

    final auxiliary = find.widgetWithText(SwitchListTile, 'Auxiliary sensor');
    await tester.ensureVisible(auxiliary);
    await tester.tap(auxiliary);
    await tester.pumpAndSettle();
    expect(
        ble.subscriptions,
        contains(
            '${BleUuids.auxiliaryService}/${BleUuids.auxiliaryChar}/${BleInputProperty.notification}'));

    ble.updateCharacteristicValue('11:22:33:44:55:66', BleUuids.auxiliaryChar,
        _auxPacket(1, List.filled(8, 999)), null);
    ble.updateCharacteristicValue(_deviceId, BleUuids.auxiliaryChar,
        _auxPacket(7, [-10, 20, 30, 40, 50, 60, 70, 800]), null);
    ble.updateCharacteristicValue(
        _deviceId, BleUuids.auxiliaryChar, Uint8List(3), null);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.scrollUntilVisible(
        find.text('ADC auxiliary · raw counts'), 400,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('CH1: -10'), findsOneWidget);
    expect(find.text('CH8: 800'), findsOneWidget);
    expect(find.textContaining('Sequence 7'), findsOneWidget);
    expect(find.text('Rejected ADC packets: 1'), findsOneWidget);
    expect(find.text('CH1: 999'), findsNothing);

    await tester.tap(find.byIcon(Icons.link_off));
    await tester.pumpAndSettle();
    await tester.tap(find.text('CONNECT'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
        find.text('ADC auxiliary · raw counts'), 400,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Waiting for auxiliary ADC data...'), findsOneWidget);
    expect(find.text('Rejected ADC packets: 1'), findsNothing);
    expect(find.text('CH1: -10'), findsNothing);
    expect(
        ble.subscriptions
            .where((entry) => entry.contains(BleUuids.auxiliaryChar)),
        hasLength(2));

    ble.updateCharacteristicValue(_deviceId, BleUuids.auxiliaryChar,
        _auxPacket(8, [11, 22, 33, 44, 55, 66, 77, 88]), null);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('CH1: 11'), findsOneWidget);
    expect(find.text('CH8: 88'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
