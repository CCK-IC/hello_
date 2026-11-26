import 'package:ble_imu_visualizer/models/protocol.dart';
import 'package:ble_imu_visualizer/widgets/device_status_top_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final scale in [1.0, 2.0]) {
    testWidgets('fits a 320 px AppBar at ${scale}x text', (tester) async {
      final snapshots = ValueNotifier(_snapshot(
          telemetry: _status(
        battery: 100,
        imuState: 1,
        imuPackets: 65535,
        adcPackets: 65534,
      )));
      addTearDown(snapshots.dispose);
      await _showBar(tester, snapshots, scale);

      for (final label in [
        'Sensor',
        'Details',
        '100%',
        'IMU initializing',
        'IMU',
        'ADC',
        '72 Hz',
        '120 Hz',
        '65535 pkt/s',
        '65534 pkt/s',
      ]) {
        expect(find.text(label).hitTestable(), findsOneWidget);
      }
      expect(find.byIcon(Icons.battery_full), findsOneWidget);
      final details =
          tester.getSize(find.widgetWithText(TextButton, 'Details'));
      expect(details.width, greaterThanOrEqualTo(48));
      expect(details.height, greaterThanOrEqualTo(48));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('clips a long name visually and exposes the full device name',
      (tester) async {
    const name = 'Sensor with an exceptionally long Bluetooth advertising name';
    final snapshots = ValueNotifier(_snapshot(deviceName: name));
    addTearDown(snapshots.dispose);
    await _showBar(tester, snapshots, 2);

    final paragraph = tester.renderObject<RenderParagraph>(find.descendant(
      of: find.text(name),
      matching: find.byType(RichText),
    ));
    expect(paragraph.didExceedMaxLines, isTrue);
    expect(paragraph.overflow, TextOverflow.ellipsis);
    final connection = find.bySemanticsLabel('Bluetooth');
    expect(tester.getSemantics(connection).value, 'Connected to $name');
    expect(find.byTooltip('Bluetooth · Connected to $name'), findsOneWidget);
  });

  testWidgets('distinguishes missing values and adapts the battery icon',
      (tester) async {
    final snapshots = ValueNotifier(
        _snapshot(connection: DeviceStatusConnection.disconnected));
    addTearDown(snapshots.dispose);
    await _showBar(tester, snapshots, 2);

    expect(find.text('Disconnected'), findsOneWidget);
    expect(find.byIcon(Icons.battery_unknown), findsOneWidget);
    expect(find.text('72 Hz'), findsNothing);

    snapshots.value = _snapshot(connection: DeviceStatusConnection.connecting);
    await tester.pump();
    expect(find.text('Connecting'), findsOneWidget);

    snapshots.value = _snapshot(statusEnabled: false, telemetry: _status());
    await tester.pump();
    expect(find.text('Status disabled'), findsOneWidget);
    expect(find.text('— pkt/s'), findsNWidgets(2));
    expect(find.text('72 Hz'), findsOneWidget);

    snapshots.value = _snapshot();
    await tester.pump();
    expect(find.text('Waiting for status'), findsOneWidget);
    expect(find.byIcon(Icons.battery_unknown), findsOneWidget);

    snapshots.value = _snapshot(telemetry: _status(battery: 8));
    await tester.pump();
    expect(find.text('8%'), findsOneWidget);
    expect(find.byIcon(Icons.battery_1_bar), findsOneWidget);
    expect(find.text('N/A pkt/s'), findsOneWidget);
    final adcRate = find.bySemanticsLabel('ADC BLE notification rate');
    expect(tester.getSemantics(adcRate).value, 'Unavailable on this firmware');

    snapshots.value = _snapshot(
      imuSampleRateHz: null,
      telemetry:
          _status(battery: 0, adcPackets: 0, imuState: 255, actualRate: 0),
    );
    await tester.pump();
    expect(find.text('0%'), findsOneWidget);
    expect(find.byIcon(Icons.battery_0_bar), findsOneWidget);
    expect(find.text('IMU unknown (255)'), findsOneWidget);
    expect(find.text('0 Hz'), findsOneWidget);
    expect(find.text('0 pkt/s'), findsOneWidget);
    expect(tester.getSemantics(adcRate).value, '0 packets per second');
    expect(tester.takeException(), isNull);
  });

  testWidgets('details scroll and update while open', (tester) async {
    final snapshots = ValueNotifier(_snapshot(telemetry: _status()));
    addTearDown(snapshots.dispose);
    await _showBar(tester, snapshots, 2);
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();

    final dialog = find.byType(AlertDialog);
    Finder detail(String value) =>
        find.descendant(of: dialog, matching: find.text(value));
    expect(detail('XIAO ESP32-S3'), findsOneWidget);
    expect(detail('Firmware'), findsOneWidget);
    expect(detail('Battery voltage'), findsOneWidget);
    expect(detail('Requested IMU sample rate'), findsOneWidget);
    expect(detail('ATT MTU'), findsOneWidget);
    expect(detail('Dropped notifications'), findsOneWidget);
    expect(detail('Discarded sensor samples'), findsOneWidget);
    expect(detail('FIFO recoveries'), findsOneWidget);
    final errors = detail('I2C errors');
    expect(errors.hitTestable(), findsNothing);
    await tester.ensureVisible(errors);
    await tester.pumpAndSettle();
    expect(errors.hitTestable(), findsOneWidget);

    snapshots.value = _snapshot(telemetry: _status(version: 2));
    await tester.pump();
    expect(detail('Combined FIFO and I2C errors'), findsOneWidget);
    expect(detail('FIFO recoveries'), findsNothing);
    expect(errors, findsNothing);

    snapshots.value = _snapshot(
      connection: DeviceStatusConnection.disconnected,
      telemetry: _status(),
    );
    await tester.pump();
    expect(detail('Disconnected'), findsOneWidget);
    expect(detail('Dropped notifications'), findsNothing);
    expect(find.text('57%'), findsNothing);
    await tester.tap(detail('Close'));
    await tester.pumpAndSettle();
    expect(dialog, findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _showBar(
  WidgetTester tester,
  ValueNotifier<DeviceStatusSnapshot> snapshots,
  double scale,
) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(320, 640);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final scaler = TextScaler.linear(scale);
  return tester.pumpWidget(MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: scaler),
      child: child!,
    ),
    home: Scaffold(
      appBar: AppBar(
        title: const Text('Monitor'),
        bottom: DeviceStatusTopBar(listenable: snapshots, textScaler: scaler),
      ),
    ),
  ));
}

DeviceStatusSnapshot _snapshot({
  DeviceStatusConnection connection = DeviceStatusConnection.connected,
  String? deviceName = 'Sensor',
  DeviceStatus? telemetry,
  bool statusEnabled = true,
  int? imuSampleRateHz = 72,
}) =>
    (
      connection: connection,
      deviceName: deviceName,
      telemetry: telemetry,
      imuSampleRateHz: imuSampleRateHz,
      adcSampleRateHz: 120,
      statusEnabled: statusEnabled,
      rawEnabled: true,
      adcEnabled: true,
      rawStalled: false,
    );

DeviceStatus _status({
  int battery = 57,
  int imuState = 2,
  int imuPackets = 20,
  int actualRate = 90,
  int? adcPackets,
  int version = 3,
}) =>
    DeviceStatus(
      version: version,
      boardName: 'XIAO ESP32-S3',
      firmwareVersion: '1.5.0',
      imuState: imuState,
      uptimeMs: 26890,
      requestedRate: 100,
      actualSensorRate: actualRate,
      notificationRate: imuPackets,
      adcNotificationRate: adcPackets,
      batteryMilliVolts: 3900,
      batteryPercent: battery,
      attMtu: 247,
      droppedNotifications: 12,
      bufferDroppedSamples: 13,
      fifoRecoveries: 14,
      i2cErrors: version == 2 ? 14 : 15,
    );
