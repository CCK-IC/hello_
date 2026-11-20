import 'dart:typed_data';
import 'dart:math' as math;
import 'dart:convert';

import 'package:ble_imu_visualizer/main.dart';
import 'package:ble_imu_visualizer/models/protocol.dart';
import 'package:ble_imu_visualizer/widgets/adc_chart.dart';
import 'package:ble_imu_visualizer/widgets/raw_imu_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

const _deviceId = 'aa:bb:cc:dd:ee:ff';
const _deviceName = 'XIAO-IMU-RAW Test';

class _FakeBlePlatform extends UniversalBlePlatform {
  bool connected = false;
  bool rejectAdcRate = false;
  final subscriptions = <String>[];
  final writes = <Uint8List>[];
  final requestedMtus = <int>[];
  int? negotiatedMtu;

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
      BleOutputProperty bleOutputProperty) async {
    writes.add(Uint8List.fromList(value));
    if (rejectAdcRate && value.first == 0x08) {
      throw StateError('Unsupported command');
    }
  }

  @override
  Future<void> setNotifiable(String deviceId, String service,
      String characteristic, BleInputProperty bleInputProperty) async {
    subscriptions.add('$service/$characteristic/$bleInputProperty');
  }

  @override
  Future<int> requestMtu(String deviceId, int expectedMtu) async {
    requestedMtus.add(expectedMtu);
    return negotiatedMtu ?? expectedMtu;
  }

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

Uint8List _batch(int kind, List<int> deltas,
    {int sequence = 100, int timestamp = 1000, bool peer = false}) {
  final slotSize = kind == 1 ? 24 : 20;
  final data = ByteData(28 + deltas.length * slotSize * 2)
    ..setUint8(0, 3)
    ..setUint8(1, kind)
    ..setUint8(2, peer ? 3 : 1)
    ..setUint8(3, deltas.length);
  for (var glove = 0; glove < (peer ? 2 : 1); glove++) {
    final metadata = 4 + glove * 12;
    data
      ..setUint32(metadata, sequence, Endian.little)
      ..setUint32(metadata + 4, timestamp, Endian.little)
      ..setUint16(metadata + 8, 25, Endian.little)
      ..setUint8(metadata + 10, kind == 3 ? 8 : 0);
    for (var i = 0; i < deltas.length; i++) {
      final offset = 28 + (i * 2 + glove) * slotSize;
      data
        ..setUint8(offset, i)
        ..setUint16(offset + 1, deltas[i], Endian.little)
        ..setUint8(offset + 3, kind == 1 ? 0x1f : 1);
      for (var j = 0; j < (kind == 1 ? 10 : 8); j++) {
        data.setInt16(
            offset + 4 + j * 2, glove * 1000 + i * 100 + j, Endian.little);
      }
    }
  }
  return data.buffer.asUint8List();
}

List<Uint8List> _fragments(Uint8List frame, int frameId) {
  final payloadSize = (frame.length + 1) ~/ 2;
  return List.generate(2, (index) {
    final payload = frame.sublist(
        index * payloadSize, math.min(frame.length, (index + 1) * payloadSize));
    final data = ByteData(8 + payload.length)
      ..setUint8(0, 0xf3)
      ..setUint8(1, frame[1])
      ..setUint16(2, frameId, Endian.little)
      ..setUint8(4, index)
      ..setUint8(5, 2)
      ..setUint16(6, frame.length, Endian.little);
    final bytes = data.buffer.asUint8List();
    bytes.setRange(8, bytes.length, payload);
    return bytes;
  });
}

Uint8List _statusBatch() {
  final bytes = ByteData(108)
    ..setUint8(0, 3)
    ..setUint8(1, 4)
    ..setUint8(2, 1)
    ..setUint8(3, 1)
    ..setUint8(4 + 14, 1)
    ..setUint8(4 + 18, 1)
    ..setUint8(4 + 19, 4)
    ..setUint16(4 + 22, 3, Endian.little)
    ..setUint32(4 + 40, 7, Endian.little);
  return bytes.buffer.asUint8List();
}

Future<void> _connectDashboard(WidgetTester tester, _FakeBlePlatform ble,
    {Future<void> Function(String, DateTime, String)? saveCsv}) async {
  UniversalBle.setInstance(ble);
  await tester.pumpWidget(MaterialApp(home: BleImuApp(saveCsv: saveCsv)));
  await tester.tap(find.byIcon(Icons.search));
  await tester.pump();
  ble.updateScanResult(BleDevice(deviceId: _deviceId, name: _deviceName));
  await tester.pump();
  await tester.tap(find.text('CONNECT'));
  await tester.pumpAndSettle();
}

Future<void> _toggle(WidgetTester tester, String label) async {
  final tile = find.widgetWithText(SwitchListTile, label);
  await tester.ensureVisible(tile);
  await tester.tap(tile);
  await tester.pumpAndSettle();
}

void _emit(_FakeBlePlatform ble, String characteristic, Uint8List frame) =>
    ble.updateCharacteristicValue(_deviceId, characteristic, frame, null);

void main() {
  test('ADC rate command uses its own opcode and validates bounds', () {
    expect(SetAdcRateCommand(1).serialize(), [0x08, 1, 0]);
    expect(SetAdcRateCommand(200).serialize(), [0x08, 200, 0]);
    expect(() => SetAdcRateCommand(0), throwsRangeError);
    expect(() => SetAdcRateCommand(201), throwsRangeError);
  });

  testWidgets('ADC rate is separate from the IMU and restores on reconnect',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final ble = _FakeBlePlatform();
    await _connectDashboard(tester, ble);
    final adcSlider = find.byWidgetPredicate(
      (widget) => widget is Slider && widget.label == 'ADC Sample Rate',
    );
    Iterable<Uint8List> adcWrites() => ble.writes.where((v) => v.first == 0x08);
    Future<void> showAdcRate() => tester.scrollUntilVisible(adcSlider, 300,
        scrollable: find.byType(Scrollable).first);
    expect(adcWrites(), isEmpty);
    await showAdcRate();

    void selectRate(double rate) {
      final slider = tester.widget<Slider>(adcSlider);
      slider.onChanged!(rate);
      slider.onChangeEnd!(rate);
    }

    selectRate(72);
    await tester.pumpAndSettle();
    expect(adcWrites().single, [0x08, 72, 0]);
    expect(find.text('Last ADC rate set by app: 72 Hz'), findsOneWidget);
    expect(find.text('IMU Sample Rate: 45 Hz'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    ble.rejectAdcRate = true;
    selectRate(90);
    await tester.pumpAndSettle();
    expect(find.text('ADC Sample Rate: 72 Hz'), findsOneWidget);
    expect(find.textContaining('firmware 1.4.1 or later'), findsOneWidget);

    Future<void> reconnect() async {
      await tester.tap(find.byTooltip('Disconnect sensor'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('CONNECT'));
      await tester.pumpAndSettle();
    }

    await reconnect();
    expect(adcWrites().last, [0x08, 72, 0]);
    expect(find.byTooltip('Disconnect sensor'), findsOneWidget);
    await showAdcRate();
    expect(find.text('Last ADC rate set by app: 72 Hz'), findsNothing);

    ble.rejectAdcRate = false;
    await reconnect();
    await showAdcRate();
    expect(adcWrites().last, [0x08, 72, 0]);
    expect(find.text('Last ADC rate set by app: 72 Hz'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('native scan requires a project name prefix or service',
      (tester) async {
    final ble = _FakeBlePlatform();
    UniversalBle.setInstance(ble);
    await tester.pumpWidget(const MaterialApp(home: BleImuApp()));
    await tester.tap(find.byIcon(Icons.search));
    await tester.pump();

    const unrelatedId = '11:22:33:44:55:66';
    ble.updateScanResult(BleDevice(
      deviceId: unrelatedId,
      name: 'Nearby XIAO-IMU-RAW',
      services: [BleUuids.batteryService],
      serviceData: {BleUuids.batteryService: Uint8List(1)},
    ));
    const nameOnly = 'xIaO-iMu-RaW-01';
    ble.updateScanResult(BleDevice(deviceId: _deviceId, name: nameOnly));
    await tester.pump();

    expect(find.text(nameOnly), findsOneWidget);
    expect(find.text(unrelatedId), findsNothing);
    expect(find.text('CONNECT'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final (serviceName, uuid) in [
    ('IMU', BleUuids.imuService),
    ('auxiliary', BleUuids.auxiliaryService),
    ('status', BleUuids.deviceStatusService),
  ]) {
    testWidgets(
        'native scan accepts $serviceName UUIDs without a matching name',
        (tester) async {
      final ble = _FakeBlePlatform();
      UniversalBle.setInstance(ble);
      await tester.pumpWidget(const MaterialApp(home: BleImuApp()));
      await tester.tap(find.byIcon(Icons.search));
      await tester.pump();

      const serviceDataId = '11:22:33:44:55:66';
      ble.updateScanResult(BleDevice(
        deviceId: _deviceId,
        name: null,
        services: [uuid],
      ));
      ble.updateScanResult(BleDevice(
        deviceId: serviceDataId,
        name: 'Sensor',
        serviceData: {uuid: Uint8List(1)},
      ));
      await tester.pump();

      expect(find.text(_deviceId), findsOneWidget);
      expect(find.text(serviceDataId), findsOneWidget);
      expect(find.text('CONNECT'), findsNWidgets(2));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('native scan lists a later qualifying advertisement only once',
      (tester) async {
    final ble = _FakeBlePlatform();
    UniversalBle.setInstance(ble);
    await tester.pumpWidget(const MaterialApp(home: BleImuApp()));
    await tester.tap(find.byIcon(Icons.search));
    await tester.pump();

    const name = 'Sensor';
    ble.updateScanResult(BleDevice(deviceId: _deviceId, name: name));
    await tester.pump();
    expect(find.text(_deviceId), findsNothing);

    ble.updateScanResult(BleDevice(
      deviceId: _deviceId,
      name: name,
      services: [BleUuids.imuService],
    ));
    await tester.pump();
    expect(find.text(_deviceId), findsOneWidget);

    ble.updateScanResult(BleDevice(deviceId: _deviceId, name: _deviceName));
    await tester.pump();
    expect(find.text(_deviceId), findsOneWidget);
    expect(find.text('CONNECT'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('narrow dashboard supports dark mode and large text',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 700));
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      tester.platformDispatcher.clearPlatformBrightnessTestValue();
    });
    final ble = _FakeBlePlatform();
    UniversalBle.setInstance(ble);
    await tester.pumpWidget(const BleImuMonitor());
    expect(Theme.of(tester.element(find.text('Find devices'))).brightness,
        Brightness.dark);
    await tester.tap(find.byTooltip('Search for Bluetooth devices'));
    await tester.pump();
    ble.updateScanResult(BleDevice(deviceId: _deviceId, name: _deviceName));
    await tester.pump();
    await tester.scrollUntilVisible(find.text('CONNECT'), 250);
    await tester.pumpAndSettle();
    await tester.tap(find.text('CONNECT'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Analyze IMU data'), findsOneWidget);
    expect(find.byTooltip('Disconnect sensor'), findsOneWidget);
    for (final heading in [
      'Device telemetry',
      'Raw ICM-20948 Data',
      'BLE subscriptions',
      'Raw data visualization',
      'ADC auxiliary · raw counts',
      'Control Commands',
    ]) {
      await tester.scrollUntilVisible(find.text(heading), 250,
          scrollable: find.byType(Scrollable).first);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('analysis page receives live packets from the connected device',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final ble = _FakeBlePlatform();
    UniversalBle.setInstance(ble);
    await tester.pumpWidget(const MaterialApp(home: BleImuApp()));
    await tester.tap(find.byIcon(Icons.search));
    await tester.pump();
    ble.updateScanResult(BleDevice(deviceId: _deviceId, name: _deviceName));
    await tester.pump();
    await tester.tap(find.text('CONNECT'));
    await tester.pumpAndSettle();
    expect(ble.writes.first, orderedEquals(SetRateCommand(45).serialize()));
    await tester.tap(find.byIcon(Icons.analytics_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('IMU frequency analysis'), findsOneWidget);

    for (var i = 0; i < 151; i++) {
      final data = ByteData(20)
        ..setUint8(0, 2)
        ..setUint8(1, 7)
        ..setUint16(2, i, Endian.little)
        ..setUint32(4, i * 40, Endian.little)
        ..setInt16(8, (1000 * math.sin(2 * math.pi * 2 * i / 25)).round(),
            Endian.little);
      ble.updateCharacteristicValue(
          _deviceId, BleUuids.rawImuChar, data.buffer.asUint8List(), null);
    }
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Observed sample rate: 25.0 Hz'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Candidate spectral peaks'), 300,
        scrollable: find.byType(Scrollable).last);
    expect(find.text('1.99 Hz'), findsOneWidget);
    ble.updateConnection(_deviceId, false);
    await tester.pump();
    expect(find.text('1.99 Hz'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'dashboard receives AUX notifications and retains them on reconnect',
      (tester) async {
    final ble = _FakeBlePlatform();
    UniversalBle.setInstance(ble);
    await tester.pumpWidget(const MaterialApp(home: BleImuApp()));

    await tester.tap(find.byIcon(Icons.search));
    await tester.pump();
    ble.updateScanResult(BleDevice(deviceId: _deviceId, name: _deviceName));
    await tester.pump();
    expect(find.text(_deviceName), findsOneWidget);
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
    expect(find.text('Waiting for auxiliary ADC data...'), findsNothing);
    expect(find.text('Rejected ADC packets: 1'), findsNothing);
    expect(find.text('CH1: -10'), findsOneWidget);
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

  testWidgets('raw batch expands history, recording and CSV with provenance',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final saved = <(String, String)>[];
    final ble = _FakeBlePlatform();
    await _connectDashboard(tester, ble, saveCsv: (csv, _, prefix) async {
      saved.add((csv, prefix));
    });
    await tester.ensureVisible(find.text('Record CSV'));
    await tester.tap(find.text('Record CSV'));
    final frame = _batch(1, [0, 20, 70], peer: true);
    _emit(ble, BleUuids.rawImuChar, frame);
    _emit(
        ble, BleUuids.rawImuChar, frame); // duplicate rows are not added twice
    final malformed = _batch(1, [0, 20], sequence: 103)..[3] = 3;
    _emit(ble, BleUuids.rawImuChar, malformed);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Save buffer CSV (3 samples)'), findsOneWidget);
    final points = tester.widget<RawImuChart>(find.byType(RawImuChart)).history;
    expect(points.map((p) => p.sample.sequence), [100, 101, 102]);
    expect(points.map((p) => p.sample.gloveId), everyElement(0));
    expect(points.map((p) => p.receivedAt).toSet(), hasLength(1));
    expect(points.last.sampledAt, points.last.receivedAt);
    expect(
        points[1].sampledAt.difference(points[0].sampledAt).inMilliseconds, 20);
    expect(
        points[2].sampledAt.difference(points[1].sampledAt).inMilliseconds, 50);
    expect(points.map((p) => p.deviceId), everyElement(_deviceId));
    expect(points.map((p) => p.sessionId).toSet(), hasLength(1));

    await tester.ensureVisible(find.text('Save buffer CSV (3 samples)'));
    await tester.tap(find.text('Save buffer CSV (3 samples)'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(saved.map((s) => s.$2), ['raw_imu_buffer', 'raw_imu']);
    for (final (csv, _) in saved) {
      final rows = const LineSplitter().convert(csv);
      expect(rows, hasLength(4));
      final header = rows.first.split(',');
      final values = rows.skip(1).map((r) => r.split(',')).toList();
      String cell(int row, String column) =>
          values[row][header.indexOf(column)];
      expect(header.take(5), [
        'received_iso8601',
        'elapsed_ms',
        'packet_version',
        'sequence',
        'sensor_timestamp_ms',
      ]);
      expect(cell(0, 'received_iso8601'), cell(2, 'received_iso8601'));
      expect(
          DateTime.parse(cell(2, 'sample_iso8601'))
              .difference(DateTime.parse(cell(0, 'sample_iso8601')))
              .inMilliseconds,
          70);
      expect(values.map((r) => r[header.indexOf('device_id')]),
          everyElement(_deviceId));
      expect(cell(0, 'session_id'), points.first.sessionId.toString());
      expect(cell(0, 'glove_slot'), '0');
      expect(cell(2, 'mag_x_count'), '206');
      expect(cell(2, 'temperature_count'), '209');
    }
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('interleaved raw and AUX fragments emit only complete batches',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final ble = _FakeBlePlatform();
    await _connectDashboard(tester, ble);
    await _toggle(tester, 'Auxiliary sensor');
    final raw = _fragments(_batch(1, [0, 17, 60]), 1);
    final aux = _fragments(_batch(3, [0, 25, 50, 80]), 1);
    final status = _fragments(_statusBatch(), 1);
    _emit(ble, BleUuids.rawImuChar, raw.first);
    _emit(ble, BleUuids.auxiliaryChar, aux.first);
    _emit(ble, BleUuids.statusChar, status.first);
    await tester.pump(const Duration(milliseconds: 50));
    expect(
        tester.widget<RawImuChart>(find.byType(RawImuChart)).history, isEmpty);
    expect(tester.widget<AdcChart>(find.byType(AdcChart)).history, isEmpty);
    expect(find.textContaining('Rejected ADC packets'), findsNothing);
    expect(find.text('Firmware: 1.4.0'), findsNothing);
    _emit(ble, BleUuids.auxiliaryChar, aux.last);
    _emit(ble, BleUuids.rawImuChar, raw.last);
    _emit(ble, BleUuids.statusChar, status.last);
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.widget<RawImuChart>(find.byType(RawImuChart)).history,
        hasLength(3));
    final points = tester.widget<AdcChart>(find.byType(AdcChart)).history;
    expect(points, hasLength(4));
    expect(points.map((p) => p.sample.channels.first), [0, 100, 200, 300]);
    expect(points.map((p) => p.receivedAt).toSet(), hasLength(1));
    expect(
        points.last.sampledAt.difference(points.first.sampledAt).inMilliseconds,
        80);
    expect(find.textContaining('Rejected ADC packets'), findsNothing);
    expect(find.text('Firmware: 1.4.0'), findsOneWidget);
    expect(find.text('Discarded sensor samples: 7'), findsOneWidget);
    // Even a valid first row of a malformed AUX frame must not be committed.
    final invalid = _batch(3, [0, 20], sequence: 104);
    invalid[invalid.length - 1] = 1; // absent peer slot must remain zero
    _emit(ble, BleUuids.auxiliaryChar, invalid);
    await tester.pump(const Duration(milliseconds: 50));
    expect(
        tester.widget<AdcChart>(find.byType(AdcChart)).history, hasLength(4));
    expect(find.text('Rejected ADC packets: 1'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('raw toggle resets partial frames and retains previous history',
      (tester) async {
    final ble = _FakeBlePlatform();
    await _connectDashboard(tester, ble);
    _emit(ble, BleUuids.rawImuChar, _batch(1, [0, 20]));
    final partial = _fragments(_batch(1, [0, 20], sequence: 102), 2);
    _emit(ble, BleUuids.rawImuChar, partial.first);
    await _toggle(tester, 'IMU raw');
    _emit(ble, BleUuids.rawImuChar, partial.last); // disabled callbacks ignored
    await _toggle(tester, 'IMU raw');
    _emit(ble, BleUuids.rawImuChar, partial.last); // cannot resume old partial
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.widget<RawImuChart>(find.byType(RawImuChart)).history,
        hasLength(2));
    _emit(ble, BleUuids.rawImuChar,
        _batch(1, [0, 35], sequence: 1, timestamp: 2));
    await tester.pump(const Duration(milliseconds: 50));
    final points = tester.widget<RawImuChart>(find.byType(RawImuChart)).history;
    expect(points, hasLength(4));
    expect(points.last.sessionId, isNot(points.first.sessionId));
    expect(points.last.sampledAt, points.last.receivedAt);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android requests MTU 247 for raw with AUX disabled',
      (tester) async {
    final ble = _FakeBlePlatform()..negotiatedMtu = 23;
    await _connectDashboard(tester, ble);
    expect(ble.requestedMtus, [247]);
    expect(find.byTooltip('Disconnect sensor'), findsOneWidget);
    final raw = _fragments(_batch(1, [0, 20]), 1);
    for (final part in raw) {
      _emit(ble, BleUuids.rawImuChar, part);
    }
    await tester.pump(const Duration(milliseconds: 50));
    await tester.scrollUntilVisible(
        find.text('Save buffer CSV (2 samples)'), 300,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Save buffer CSV (2 samples)'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
      'reconnect resets partial frames and timelines, retaining buffers',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final ble = _FakeBlePlatform();
    await _connectDashboard(tester, ble);
    await _toggle(tester, 'Auxiliary sensor');
    _emit(ble, BleUuids.rawImuChar, _batch(1, [0, 20]));
    _emit(ble, BleUuids.auxiliaryChar, _batch(3, [0, 25]));
    final raw = _fragments(_batch(1, [0, 20], sequence: 102), 2);
    final aux = _fragments(_batch(3, [0, 25], sequence: 102), 2);
    _emit(ble, BleUuids.rawImuChar, raw.first);
    _emit(ble, BleUuids.auxiliaryChar, aux.first);
    await tester.tap(find.byTooltip('Disconnect sensor'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('CONNECT'));
    await tester.pumpAndSettle();
    _emit(ble, BleUuids.rawImuChar, raw.last);
    _emit(ble, BleUuids.auxiliaryChar, aux.last);
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.widget<RawImuChart>(find.byType(RawImuChart)).history,
        hasLength(2));
    expect(
        tester.widget<AdcChart>(find.byType(AdcChart)).history, hasLength(2));

    _emit(ble, BleUuids.rawImuChar,
        _batch(1, [0, 35], sequence: 1, timestamp: 5000));
    _emit(ble, BleUuids.auxiliaryChar,
        _batch(3, [0, 35], sequence: 1, timestamp: 5000));
    await tester.pump(const Duration(milliseconds: 50));
    final rawPoints =
        tester.widget<RawImuChart>(find.byType(RawImuChart)).history;
    final adcPoints = tester.widget<AdcChart>(find.byType(AdcChart)).history;
    expect(rawPoints, hasLength(4));
    expect(adcPoints, hasLength(4));
    expect(rawPoints.last.sessionId, isNot(rawPoints.first.sessionId));
    expect(rawPoints.last.sampledAt, rawPoints.last.receivedAt);
    expect(adcPoints.last.sampledAt, adcPoints.last.receivedAt);

    final nextAux = _fragments(_batch(3, [0, 20], sequence: 3), 3);
    _emit(ble, BleUuids.auxiliaryChar, nextAux.first);
    await _toggle(tester, 'Auxiliary sensor');
    await _toggle(tester, 'Auxiliary sensor');
    _emit(ble, BleUuids.auxiliaryChar, nextAux.last);
    _emit(ble, BleUuids.auxiliaryChar,
        _batch(3, [0, 20], sequence: 1, timestamp: 9000));
    await tester.pump(const Duration(milliseconds: 50));
    final afterToggle = tester.widget<AdcChart>(find.byType(AdcChart)).history;
    expect(afterToggle, hasLength(6));
    expect(afterToggle.last.sampledAt, afterToggle.last.receivedAt);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('frequency analysis receives every local row of v3 batches',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final ble = _FakeBlePlatform();
    await _connectDashboard(tester, ble);
    await tester.tap(find.byTooltip('Analyze IMU data'));
    await tester.pumpAndSettle();
    for (var base = 0; base < 151; base += 8) {
      final count = math.min(8, 151 - base);
      final frame = _batch(1, List.generate(count, (i) => i * 40),
          sequence: base, timestamp: base * 40, peer: true);
      final data = ByteData.sublistView(frame);
      for (var i = 0; i < count; i++) {
        data.setInt16(
            28 + i * 48 + 4,
            (1000 * math.sin(2 * math.pi * 2 * (base + i) / 25)).round(),
            Endian.little);
      }
      _emit(ble, BleUuids.rawImuChar, frame);
    }
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Observed sample rate: 25.0 Hz'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Candidate spectral peaks'), 300,
        scrollable: find.byType(Scrollable).last);
    expect(find.text('1.99 Hz'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows setup retains raw-first subscription protections',
      (tester) async {
    final ble = _FakeBlePlatform();
    await _connectDashboard(tester, ble);
    expect(find.byTooltip('Disconnect sensor'), findsOneWidget);
    expect(ble.requestedMtus, isEmpty);
    expect(ble.subscriptions, [
      '${BleUuids.imuService}/${BleUuids.rawImuChar}/${BleInputProperty.notification}',
    ]);
    expect(ble.writes.first, orderedEquals(SetRateCommand(45).serialize()));
    await _toggle(tester, 'Auxiliary sensor');
    expect(ble.requestedMtus, isEmpty);
    expect(ble.subscriptions.last,
        '${BleUuids.auxiliaryService}/${BleUuids.auxiliaryChar}/${BleInputProperty.notification}');
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
