import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:universal_ble/universal_ble.dart';

import 'models/protocol.dart';
import 'widgets/imu_3d_view.dart';
import 'widgets/euler_chart.dart';
import 'widgets/control_panel.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    themeMode: ThemeMode.light,
    home: BleImuApp(),
  ));
}

class BleImuApp extends StatefulWidget {
  const BleImuApp({super.key});

  @override
  State<BleImuApp> createState() => _BleImuAppState();
}

class _BleImuAppState extends State<BleImuApp> {
  BleDevice? _connectedDevice;
  bool _isScanning = false;
  final List<BleDevice> _scannedDevices = [];

  QuaternionSample? _latestSample;
  DeviceStatus? _latestStatus;

  // Chart buffers
  final List<double> _rollHistory = [];
  final List<double> _pitchHistory = [];
  final List<double> _yawHistory = [];
  static const int _maxDataPoints = 80;

  final List<String> _commandHistory = [];

  @override
  void initState() {
    super.initState();
    _initBle();
  }

  void _initBle() {
    UniversalBle.onScanResult = (device) {
      if (!_scannedDevices.any((d) => d.deviceId == device.deviceId)) {
        setState(() => _scannedDevices.add(device));
      }
    };

    UniversalBle.onValueChange = (deviceId, characteristicId, value,Null) {//timestamp is optional and can be null
      final char = characteristicId.toLowerCase();
      if (char == BleUuids.quaternionChar.toLowerCase()) {
        final sample = QuaternionSample.decode(value);
        if (sample != null) {
          setState(() {
            _latestSample = sample;
            _rollHistory.add(sample.roll);
            _pitchHistory.add(sample.pitch);
            _yawHistory.add(sample.yaw);
            if (_rollHistory.length > _maxDataPoints) _rollHistory.removeAt(0);
            if (_pitchHistory.length > _maxDataPoints) _pitchHistory.removeAt(0);
            if (_yawHistory.length > _maxDataPoints) _yawHistory.removeAt(0);
          });
        }
      } else if (char == BleUuids.statusChar.toLowerCase()) {
        final status = DeviceStatus.decode(value);
        if (status != null) {
          setState(() => _latestStatus = status);
        }
      }
    };

    UniversalBle.onConnectionChange = (deviceId, isConnected, error) {
      if (!isConnected && _connectedDevice?.deviceId == deviceId) {
        setState(() {
          _connectedDevice = null;
          _latestSample = null;
        });
      }
    };
  }

Future<void> _startScan() async {
  setState(() {
    _scannedDevices.clear();
    _isScanning = true;
  });

  // On Web, all services you intend to access MUST be declared in the scan filter,
  // otherwise Web Bluetooth throws a SecurityError.
  // On Android, we can scan broadly or with filters.
  final ScanFilter? scanFilter = kIsWeb
      ? ScanFilter(
          withServices: [
            BleUuids.imuService,
            BleUuids.deviceStatusService,
          ],
        )
      : null;

  try {
    await UniversalBle.startScan(scanFilter: scanFilter);
  } catch (e) {
    debugPrint("Scan failed: $e");
    setState(() => _isScanning = false);
    return;
  }

  Future.delayed(const Duration(seconds: 6), () async {
    await UniversalBle.stopScan();
    if (mounted) setState(() => _isScanning = false);
  });
}

  Future<void> _connect(BleDevice device) async {
  await UniversalBle.stopScan();
  setState(() => _isScanning = false);

  try {
    await UniversalBle.connect(device.deviceId);
    setState(() => _connectedDevice = device);

    // CRITICAL: On Web, NEVER call discoverServices() without arguments,
    // as it invokes getPrimaryServices() which trips over blocklisted 0x1800.
    // Android native DOES need discoverServices() to populate Android's GATT cache.
    if (!kIsWeb) {
      await UniversalBle.discoverServices(device.deviceId);
    }

    // Small delay to ensure the GATT connection is stable before subscribing
    await Future.delayed(const Duration(milliseconds: 200));

    // 1. Subscribe to Quaternion Stream (IMU Service)
    await UniversalBle.setNotifiable(
      device.deviceId,
      BleUuids.imuService,
      BleUuids.quaternionChar,
      BleInputProperty.notification,
    );

    // 2. Subscribe to Device Status Stream
    await UniversalBle.setNotifiable(
      device.deviceId,
      BleUuids.deviceStatusService,
      BleUuids.statusChar,
      BleInputProperty.notification,
    );
  } catch (e) {
    debugPrint("Connection or Subscription Error: $e");
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text("Connection failed: $e"),
        backgroundColor: Colors.red,
      ),
    );
  }
}


  Future<void> _disconnect() async {
    if (_connectedDevice != null) {
      await UniversalBle.disconnect(_connectedDevice!.deviceId);
      setState(() => _connectedDevice = null);
    }
  }

  Future<void> _sendCommand(BleControlCommand cmd) async {
    if (_connectedDevice == null) throw Exception("Device not connected");
    final payload = cmd.serialize();

    await UniversalBle.writeValue(
      _connectedDevice!.deviceId,
      BleUuids.deviceStatusService,
      BleUuids.controlChar,
      payload,
      BleOutputProperty.withResponse,
    );

    setState(() {
      _commandHistory.add("[${DateTime.now().toIso8601String().substring(11, 19)}] ${cmd.name}");
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color.fromARGB(255, 135, 217, 224),
      appBar: AppBar(
        title: const Text("IMU BLE 3D Attitude Monitor"),
        backgroundColor: const Color.fromARGB(255, 134, 152, 201),
        actions: [
          if (_connectedDevice == null)
            IconButton(
              icon: Icon(_isScanning ? Icons.stop : Icons.search),
              onPressed: _isScanning ? () => UniversalBle.stopScan() : _startScan,
            )
          else
            IconButton(
              icon: const Icon(Icons.link_off, color: Colors.redAccent),
              onPressed: _disconnect,
            ),
        ],
      ),
      body: _connectedDevice == null ? _buildScannerList() : _buildDashboard(),
    );
  }

  Widget _buildScannerList() {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (_isScanning) const LinearProgressIndicator(),
        const SizedBox(height: 12),
        const Text("Available BLE Devices", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 8),
        if (_scannedDevices.isEmpty && !_isScanning)
          const Padding(
            padding: EdgeInsets.all(24.0),
            child: Center(child: Text("No devices found. Tap Search to discover.")),
          ),
        ..._scannedDevices.map(
          (d) => Card(
            color: const Color.fromARGB(235, 120, 137, 185),
            child: ListTile(
              title: Text(d.name?.isNotEmpty == true ? d.name! : "Unnamed Sensor"),
              subtitle: Text(d.deviceId, style: const TextStyle(fontFamily: 'monospace')),
              trailing: ElevatedButton(
                child: const Text("CONNECT"),
                onPressed: () => _connect(d),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDashboard() {
    final quat = _latestSample;
    final status = _latestStatus;

    return LayoutBuilder(builder: (context, constraints) {
      final isWide = constraints.maxWidth > 800;

      final visualizationColumn = Column(
        children: [
          // Warnings Banner (Synthetic / Degraded indicator)
          if (quat?.flags.isSynthetic == true || quat?.flags.isDegraded == true)
            Container(
              padding: const EdgeInsets.all(8),
              margin: const EdgeInsets.symmetric(vertical: 4),
              color: Colors.amber.shade900,
              child: Row(
                children: [
                  const Icon(Icons.warning, color: Colors.white),
                  const SizedBox(width: 8),
                  Text(
                    quat!.flags.isSynthetic ? "WARNING: Synthetic fallback data" : "WARNING: Degraded Mode",
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),

          // 3D Canvas
          Expanded(
            flex: 5,
            child: Card(
              color: const Color.fromARGB(235, 159, 160, 163),
              child: Stack(
                children: [
                  Imu3dView(
                    q0: quat?.w ?? 1.0,
                    q1: quat?.x ?? 0.0,
                    q2: quat?.y ?? 0.0,
                    q3: quat?.z ?? 0.0,
                  ),
                  Positioned(
                    top: 10,
                    left: 10,
                    child: Text(
                      "Roll: ${quat?.roll.toStringAsFixed(1)}°\n"
                      "Pitch: ${quat?.pitch.toStringAsFixed(1)}°\n"
                      "Yaw: ${quat?.yaw.toStringAsFixed(1)}°",
                      style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Realtime Euler Angle Plot
          Expanded(
            flex: 4,
            child: EulerChart(
              rollHistory: _rollHistory,
              pitchHistory: _pitchHistory,
              yawHistory: _yawHistory,
            ),
          ),
        ],
      );

      final statusAndControlsColumn = ListView(
        children: [
          // Telemetry and Status Details
          Card(
            color: const Color.fromARGB(80, 30, 34, 45),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("Board: ${status?.boardName ?? 'Seeed XIAO'} | FW: ${status?.firmwareVersion ?? 'v1.x'}",
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  const Divider(),
                  Text("IMU State: ${status?.imuStateString ?? 'Running'}"),
                  Text("Battery: ${status?.batteryMilliVolts ?? 0} mV (${status?.batteryPercent ?? 0}%)"),
                  Text("Sensor Sample Rate: ${status?.actualSensorRate ?? 0} Hz"),
                  Text("BLE Notification Rate: ${status?.notificationRate ?? 0} Hz"),
                  Text("Uptime: ${((status?.uptimeMs ?? 0) / 1000).toStringAsFixed(1)} s"),
                  Text("Dropped Notifications: ${status?.droppedNotifications ?? 0}"),
                  Text("FIFO / I2C Recoveries: ${status?.fifoRecoveries ?? 0}"),
                ],
              ),
            ),
          ),
          ControlPanel(
            onSendCommand: _sendCommand,
            commandHistory: _commandHistory,
          ),
        ],
      );

      return isWide
          ? Row(
              children: [
                Expanded(flex: 3, child: visualizationColumn),
                Expanded(flex: 2, child: statusAndControlsColumn),
              ],
            )
          : Column(
              children: [
                Expanded(flex: 6, child: visualizationColumn),
                Expanded(flex: 4, child: statusAndControlsColumn),
              ],
            );
    });
  }
}