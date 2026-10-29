import "dart:async";
import "dart:convert";
import "dart:typed_data";

import "package:file_saver/file_saver.dart";
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:universal_ble/universal_ble.dart';

import "models/raw_imu_history.dart";
import "models/protocol.dart";
import "widgets/raw_imu_chart.dart";
// import 'widgets/imu_3d_view.dart';
// import 'widgets/euler_chart.dart';
import 'widgets/control_panel.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    themeMode: ThemeMode.light,
    home: BleImuApp(),
  ));
}

class BleOperationException implements Exception {
  final String operation;
  final Object cause;

  const BleOperationException(this.operation, this.cause);

  @override
  String toString() => "$operation failed: $cause";
}

class BleImuApp extends StatefulWidget {
  const BleImuApp({super.key});

  @override
  State<BleImuApp> createState() => _BleImuAppState();
}

class _BleImuAppState extends State<BleImuApp> {
  Timer? _uiRefreshTimer;
  Timer? _scanTimer;
  bool _uiRefreshPending = false;

  void _scheduleUiRefresh() {
    if (_uiRefreshPending || !mounted) return;

    _uiRefreshPending = true;
    _uiRefreshTimer = Timer(const Duration(milliseconds: 40), () {
      _uiRefreshPending = false;
      if (mounted) setState(() {});
    });
  }
  // static const Duration _normalConnectionTimeout = Duration(seconds: 20);
  // static const Duration _windowsConnectionTimeout = Duration(seconds: 45);
  static const Duration _windowsGattDelay = Duration(milliseconds: 350);
  static const Duration _normalGattDelay = Duration(milliseconds: 80);

  void _handleRawValue(Uint8List value) {
    final sample = RawImuSample.decode(value);

    if (sample == null) {
      _invalidRawPacketCount++;
      _scheduleUiRefresh();
      return;
    }

    final previous = _latestRawSample;
    if (previous != null &&
        previous.version == sample.version &&
        !sample.isNewerThan(previous)) {
      return;
    }

    final point = RawImuHistoryPoint(
      receivedAt: DateTime.now(),
      sample: sample,
    );

    _latestRawSample = sample;
    _rawHistory.add(point);

    if (_recordingRawCsv) {
      _rawRecording.add(point);
    }

    _pruneRawHistory(point.receivedAt);
    _scheduleUiRefresh();
  }

  DateTime _lastHistoryPrune = DateTime.fromMillisecondsSinceEpoch(0);

  void _pruneRawHistory(DateTime now) {
    if (now.difference(_lastHistoryPrune) < const Duration(seconds: 1)) {
      return;
    }

    _lastHistoryPrune = now;
    final cutoff = now.subtract(_rawHistoryRetention);

    var removeCount = 0;
    while (removeCount < _rawHistory.length &&
        _rawHistory[removeCount].receivedAt.isBefore(cutoff)) {
      removeCount++;
    }

    if (removeCount > 0) {
      _rawHistory.removeRange(0, removeCount);
    }
  }

  String? _pendingDeviceId;
  bool _linkConnected = false;
  bool _connectionLostDuringSetup = false;

  void _ensureSetupConnected() {
    if (!_linkConnected || _connectionLostDuringSetup) {
      throw StateError("Device disconnected during BLE setup");
    }
  }

  bool _sameDevice(String? first, String? second) {
  if (first == null || second == null) return false;
  return first.toLowerCase() == second.toLowerCase();
}

  BleDevice? _connectedDevice;
  bool _isScanning = false;
  final List<BleDevice> _scannedDevices = [];

  Completer<void>? _connectionCompleter;
  bool _connecting = false;
  String? _connectionError;

  final Map<String, bool> _enabledStreams = {
    "quaternion": true,
    "rawImu": true,
    "auxiliary": false,
    "status": true,
  };

  final List<RawImuHistoryPoint> _rawHistory = [];
  static const Duration _rawHistoryRetention = Duration(minutes: 10);

  final Set<RawSensorType> _selectedRawSensors = {
    RawSensorType.accelerometer,
  };
  Duration _rawChartPeriod = const Duration(seconds: 10);

  bool _recordingRawCsv = false;
  Duration _rawRecordingPeriod = const Duration(seconds: 10);
  DateTime? _rawRecordingStartedAt;
  Timer? _rawRecordingTimer;
  final List<RawImuHistoryPoint> _rawRecording = [];

  // QuaternionSample? _latestSample;
  RawImuSample? _latestRawSample;
  DeviceStatus? _latestStatus;
  int _invalidRawPacketCount = 0;
  // Chart buffers
  // final List<double> _rollHistory = [];
  // final List<double> _pitchHistory = [];
  // final List<double> _yawHistory = [];
  // static const int _maxDataPoints = 80;

  final List<String> _commandHistory = [];

  @override
  void initState() {
    super.initState();
    // Windows peers have stalled while enabling the status CCC. Keep the
    // connection usable and let the user opt in to status notifications.
    if (_isWindows) _enabledStreams["status"] = false;
    _initBle();
  }

  late final StreamController<BleCharacteristicValue> _bleDataController;
  StreamSubscription<BleCharacteristicValue>? _bleDataSubscription;
  void _initBle() {
    UniversalBle.queueType = QueueType.global;
    UniversalBle.onScanResult = (device) {
      if (!_scannedDevices.any((d) => d.deviceId == device.deviceId)) {
        setState(() => _scannedDevices.add(device));
      }
    };

    //  Best Practice: Push data straight into a stream controller or separate isolate
    // final _bleDataController = StreamController<({String deviceId, String characteristicId, Uint8List value})>();
    // _bleDataController = StreamController<BleCharacteristicValue >();
    _bleDataController =
        StreamController<BleCharacteristicValue>.broadcast(sync: true);
    

    UniversalBle.onValueChange = (BleCharacteristicValue update) {//timestamp is optional and can be null
      // _bleDataController.sink.add( characteristicId: update.characteristicId, deviceId: update.deviceId,value: update.value);
      // _bleDataController.sink.add( update);
      if (!_bleDataController.isClosed) {
        _bleDataController.add(update);
      }
    };

    void _handleCharacteristicValue(BleCharacteristicValue data) {
      if (!_sameDevice(data.deviceId, _connectedDevice?.deviceId) &&
          !_sameDevice(data.deviceId, _pendingDeviceId)) {
        return;
      }

      final characteristic = data.characteristicId.toLowerCase();

      if (characteristic == BleUuids.rawImuChar.toLowerCase()) {
        _handleRawValue(data.value);
      } else if (characteristic == BleUuids.statusChar.toLowerCase()) {
        final status = DeviceStatus.decode(data.value);
        if (status != null) {
          _latestStatus = status;
          _scheduleUiRefresh();
        }
      }
    }

    _bleDataSubscription =
        _bleDataController.stream.listen(_handleCharacteristicValue);

    // UniversalBle.onConnectionChange = (deviceId, isConnected, error) {
    UniversalBle.onConnectionChange = (BleConnectionChange change) {
      if (!_sameDevice(_pendingDeviceId, change.deviceId) &&
          !_sameDevice(_connectedDevice?.deviceId, change.deviceId)) {
        return;
      }

      debugPrint(
        "BLE: connection changed connected=${change.isConnected} "
        "error=${change.error}",
      );

      final completer = _connectionCompleter;

      if (change.isConnected) {
        _linkConnected = true;

        if (completer != null && !completer.isCompleted) {
          completer.complete();
        }
        return;
      }

      final wasConnected = _linkConnected;
      _linkConnected = false;
      if (_sameDevice(_pendingDeviceId, change.deviceId) &&
          (wasConnected || change.error != null)) {
        _connectionLostDuringSetup = true;
      }

      // Some stacks can emit a transient disconnected state while starting.
      // Reject immediately only when an error is supplied or a link was active.
      if (completer != null &&
          !completer.isCompleted &&
          (change.error != null || wasConnected)) {
        completer.completeError(
          StateError(change.error?.toString() ?? "Device disconnected"),
        );
      }

      if (wasConnected && mounted) {
        setState(() {
          _connectedDevice = null;
          _latestRawSample = null;
          _latestStatus = null;
          if (_pendingDeviceId == null) _connecting = false;
          _connectionError = change.error?.toString() ?? "Device disconnected";
        });
      }
    };
  }

Future<void> _startScan() async {
  _scanTimer?.cancel();
  setState(() {
    _scannedDevices.clear();
    _isScanning = true;
    _connectionError = null;
  });

  // On Web, all services you intend to access MUST be declared in the scan filter,
  // otherwise Web Bluetooth throws a SecurityError.
  // On Android, we can scan broadly or with filters.
  final ScanFilter? scanFilter = kIsWeb
      ? ScanFilter(
          withServices: [
            BleUuids.deviceStatusService,
            BleUuids.imuService,
            BleUuids.auxiliaryService,
          ],
          // The firmware puts its name in the primary advertisement and the
          // service UUID in the scan response. macOS Chrome may see only one.
          withNamePrefix: ["XIAO-IMU-RAW"],
        )
      : null;

  try {
    await UniversalBle.startScan(scanFilter: scanFilter);
  } catch (e) {
    debugPrint("Scan failed: $e");
    if (mounted) {
      setState(() {
        _isScanning = false;
        _connectionError = "Scan failed: $e";
      });
    }
    return;
  }

  if (!mounted || !_isScanning) return;
  _scanTimer = Timer(const Duration(seconds: 6), () async {
    try {
      await UniversalBle.stopScan();
    } finally {
      if (mounted) setState(() => _isScanning = false);
    }
  });
}

  Future<void> _connect(BleDevice device) async {
    if (_connecting) return;
    _scanTimer?.cancel();

    try {
      await UniversalBle.stopScan();
    } catch (_) {
      // Scanning may already have stopped.
    }

    final deviceId = device.deviceId;

    setState(() {
      _isScanning = false;
      _connecting = true;
      _connectionError = null;
    });

    _pendingDeviceId = deviceId;
    _linkConnected = false;
    _connectionLostDuringSetup = false;
    _connectionCompleter = Completer<void>();

    try {
      debugPrint("BLE: connecting to $deviceId");

      await UniversalBle.connect(deviceId).timeout(
        _isWindows
            ? const Duration(seconds: 30)
            : const Duration(seconds: 15),
      );

      // Some implementations complete connect() before sending the callback.
      if (!_linkConnected) {
        await _connectionCompleter!.future.timeout(
          _isWindows
              ? const Duration(seconds: 20)
              : const Duration(seconds: 10),
        );
      }
      _ensureSetupConnected();

      debugPrint("BLE: physical connection established");

      await Future<void>.delayed(_gattDelay);
      _ensureSetupConnected();

      await _retryGattOperation(
        "Service discovery",
        () => UniversalBle.discoverServices(deviceId),
      );
      _ensureSetupConnected();

      debugPrint("BLE: service discovery completed");

      await Future<void>.delayed(_gattDelay);
      _ensureSetupConnected();
      if ((_isWindows || _isMacChrome) &&
          _enabledStreams["rawImu"] == true) {
        final initialRateHz = _isMacChrome ? 10 : 25;
        debugPrint("BLE: setting initial raw stream rate to $initialRateHz Hz");
        await UniversalBle.write(
          deviceId,
          BleUuids.deviceStatusService,
          BleUuids.controlChar,
          Uint8List.fromList([0x01, initialRateHz, 0]),
          timeout: const Duration(seconds: 15),
        );
        _ensureSetupConnected();
      }
      await _applyEnabledSubscriptions(deviceId);
      _ensureSetupConnected();

      if (!mounted) return;

      setState(() {
        _connectedDevice = device;
        _connecting = false;
        _connectionError = null;
      });

      debugPrint("BLE: connection initialization completed");
    } catch (error, stackTrace) {
      debugPrint("BLE initialization failed: $error\n$stackTrace");

      try {
        await UniversalBle.disconnect(deviceId);
      } catch (_) {
        // Preserve the original failure.
      }

      if (mounted) {
        setState(() {
          _connectedDevice = null;
          _connecting = false;
          _connectionError = "BLE setup failed: $error";
        });
      }
    } finally {
      _pendingDeviceId = null;
      _connectionCompleter = null;
    }
  }

  bool get _isWindows =>
      defaultTargetPlatform == TargetPlatform.windows;

  bool get _isMacChrome =>
      kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  Duration get _gattDelay =>
      _isWindows
          ? _windowsGattDelay
          : _isMacChrome
              ? const Duration(milliseconds: 800)
              : _normalGattDelay;



Future<T> _retryGattOperation<T>(
  String operationName,
  Future<T> Function() operation, {
  int attempts = 3,
}) async {
  Object? lastError;

  for (var attempt = 1; attempt <= attempts; attempt++) {
    try {
      return await operation().timeout(
        _isWindows
            ? const Duration(seconds: 20)
            : const Duration(seconds: 12),
      );
    } catch (error) {
      lastError = error;
      debugPrint(
        "$operationName attempt $attempt/$attempts failed: $error",
      );

      if (attempt < attempts) {
        await Future<void>.delayed(
          Duration(milliseconds: 500 * attempt),
        );
      }
    }
  }

  throw BleOperationException(
    operationName,
    lastError ?? StateError("Unknown BLE error"),
  );
}
  // Future<void> _applyEnabledSubscriptions(String deviceId) async {
    // await _setStreamSubscription(
    //   deviceId: deviceId,
    //   serviceUuid: BleUuids.imuService,
    //   characteristicUuid: BleUuids.quaternionChar,
    //   enabled: _enabledStreams["quaternion"]!,
    // );

  Future<void> _applyEnabledSubscriptions(String deviceId) async {
    // Establish status while the device is not yet sending raw samples.
    if (_enabledStreams["status"] == true) {
      await _subscribe(
        deviceId,
        BleUuids.deviceStatusService,
        BleUuids.statusChar,
      );
    }

    if (_enabledStreams["auxiliary"] == true) {
      await _subscribe(
        deviceId,
        BleUuids.auxiliaryService,
        BleUuids.auxiliaryChar,
      );
    }

    if (_enabledStreams["rawImu"] == true) {
      await _subscribe(
        deviceId,
        BleUuids.imuService,
        BleUuids.rawImuChar,
      );
    }
  }

  Future<void> _setSubscription(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
    bool enabled,
  ) async {
    // A timed-out WinRT CCC write can still be active. Do not launch a second
    // write to the same characteristic while the first one is unresolved.
    const timeout = Duration(seconds: 30);
    if (enabled) {
      await UniversalBle.subscribeNotifications(
        deviceId,
        serviceUuid,
        characteristicUuid,
        timeout: timeout,
      );
    } else {
      await UniversalBle.unsubscribe(
        deviceId,
        serviceUuid,
        characteristicUuid,
        timeout: timeout,
      );
    }
  }

  Future<void> _subscribe(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) async {
    debugPrint("BLE: enabling notifications $serviceUuid/$characteristicUuid");
    await _setSubscription(deviceId, serviceUuid, characteristicUuid, true);
    debugPrint("BLE: notifications enabled $serviceUuid/$characteristicUuid");

    await Future<void>.delayed(_gattDelay);
  }

  // Future<void> _setStreamSubscription({
  //   required String deviceId,
  //   required String serviceUuid,
  //   required String characteristicUuid,
  //   required bool enabled,
  // }) async {
  //   await _retryGattOperation(
  //     "$serviceUuid/$characteristicUuid notification setup",
  //     () => UniversalBle.setNotifiable(
  //       deviceId,
  //       serviceUuid,
  //       characteristicUuid,
  //       enabled
  //           ? BleInputProperty.notification
  //           : BleInputProperty.disabled,
  //     ),
  //   );

  //   await Future<void>.delayed(_gattDelay);
  // }

  Future<void> _toggleStream(String key, bool enabled) async {
    final previous = _enabledStreams[key]!;

    setState(() => _enabledStreams[key] = enabled);

    final device = _connectedDevice;
    if (device == null) return;

    late final String serviceUuid;
    late final String characteristicUuid;

    switch (key) {
      // case "quaternion":
      //   serviceUuid = BleUuids.imuService;
      //   characteristicUuid = BleUuids.quaternionChar;
      //   break;
      case "rawImu":
        serviceUuid = BleUuids.imuService;
        characteristicUuid = BleUuids.rawImuChar;
        break;
      case "auxiliary":
        serviceUuid = BleUuids.auxiliaryService;
        characteristicUuid = BleUuids.auxiliaryChar;
        break;
      case "status":
        serviceUuid = BleUuids.deviceStatusService;
        characteristicUuid = BleUuids.statusChar;
        break;
      default:
        return;
    }

    try {
      await _setSubscription(
        device.deviceId, serviceUuid, characteristicUuid, enabled);

      if (!mounted) return;

      setState(() {
        // if (!enabled && key == "quaternion") {
        //   _latestSample = null;
        // } else 
        if (!enabled && key == "rawImu") {
          _latestRawSample = null;
        } else if (!enabled && key == "status") {
          _latestStatus = null;
        }
      });
    } catch (error) {
      if (!mounted) return;

      setState(() {
        _enabledStreams[key] = previous;
        _connectionError = enabled
            ? "Could not subscribe to $key: $error"
            : "Could not unsubscribe from $key: $error";
      });
    }
  }


  Future<void> _disconnect() async {
    _rawRecordingTimer?.cancel();

    if (_connectedDevice != null) {
      await UniversalBle.disconnect(_connectedDevice!.deviceId);
      setState(() {
        _connectedDevice = null;
        // _latestSample = null;
        _latestRawSample = null;
        _rawRecording.clear();
        _recordingRawCsv = false;
      });
    }
  }
  @override
  void dispose() {
    _rawRecordingTimer?.cancel();
    _scanTimer?.cancel();
     _uiRefreshTimer?.cancel();
    _bleDataSubscription?.cancel();
    _bleDataController.close();

    UniversalBle.onScanResult = null;
    UniversalBle.onValueChange = null;
    UniversalBle.onConnectionChange = null;

    final device = _connectedDevice;
    if (device != null) {
      unawaited(UniversalBle.disconnect(device.deviceId));
    }
    super.dispose();
  }

  Future<void> _sendCommand(BleControlCommand cmd) async {
    if (_connectedDevice == null) throw Exception("Device not connected");
    final payload = cmd.serialize();
    final deviceId = _connectedDevice!.deviceId;
    await UniversalBle.write(
      deviceId,
      BleUuids.deviceStatusService,
      BleUuids.controlChar,
      payload,
      timeout: const Duration(seconds: 15),
    );

    if (!mounted) return;
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
        // if (_connecting)
        //   const Padding(
        //     padding: EdgeInsets.only(top: 8),
        //     child: LinearProgressIndicator(),
        //   ),
        // if (_connectionError != null)
        //   Padding(
        //     padding: const EdgeInsets.only(top: 8),
        //     child: Text(
        //       _connectionError!,
        //       style: const TextStyle(color: Colors.redAccent),
        //     ),
        //   ),
        ],
      ),
      
      body: _connecting
        ? const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 12),
                Text("Connecting and discovering services..."),
              ],
            ),
          )
        : _connectedDevice == null
            ? _buildScannerList()
            : _buildDashboard(),
        );
  }

  Widget _buildScannerList() {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (_connectionError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(_connectionError!,
                style: const TextStyle(color: Colors.red)),
          ),
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
    // final quat = _latestSample;
    final raw = _latestRawSample;
    final status = _latestStatus;

    return LayoutBuilder(builder: (context, constraints) {
      final isWide = constraints.maxWidth > 800;

      // final visualizationColumn = Column(
      //   children: [
      //     // Warnings Banner (Synthetic / Degraded indicator)
      //     if (quat?.flags.isSynthetic == true || quat?.flags.isDegraded == true)
      //       Container(
      //         padding: const EdgeInsets.all(8),
      //         margin: const EdgeInsets.symmetric(vertical: 4),
      //         color: Colors.amber.shade900,
      //         child: Row(
      //           children: [
      //             const Icon(Icons.warning, color: Colors.white),
      //             const SizedBox(width: 8),
      //             Text(
      //               quat!.flags.isSynthetic ? "WARNING: Synthetic fallback data" : "WARNING: Degraded Mode",
      //               style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      //             ),
      //           ],
      //         ),
      //       ),

      //     // 3D Canvas
      //     Expanded(
      //       flex: 5,
      //       child: Card(
      //         color: const Color.fromARGB(235, 159, 160, 163),
      //         child: Stack(
      //           children: [
      //             Imu3dView(
      //               q0: quat?.w ?? 1.0,
      //               q1: quat?.x ?? 0.0,
      //               q2: quat?.y ?? 0.0,
      //               q3: quat?.z ?? 0.0,
      //             ),
      //             Positioned(
      //               top: 10,
      //               left: 10,
      //               child: Text(
      //                 "Roll: ${quat?.roll.toStringAsFixed(1)}°\n"
      //                 "Pitch: ${quat?.pitch.toStringAsFixed(1)}°\n"
      //                 "Yaw: ${quat?.yaw.toStringAsFixed(1)}°",
      //                 style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold),
      //               ),
      //             ),
      //           ],
      //         ),
      //       ),
      //     ),

      //     // Realtime Euler Angle Plot
      //     Expanded(
      //       flex: 4,
      //       child: EulerChart(
      //         rollHistory: _rollHistory,
      //         pitchHistory: _pitchHistory,
      //         yawHistory: _yawHistory,
      //       ),
      //     ),
      //   ],
      // );

      final statusAndControlsColumn = ListView(
        children: [
          if (_connectionError != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(_connectionError!,
                  style: const TextStyle(color: Colors.red)),
            ),
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
          Card(
            color: const Color.fromARGB(255, 125, 142, 189),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.sensors, size: 18),
                      SizedBox(width: 8),
                      Text(
                        "Raw ICM-20948 Data",
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    "Native raw sensor stream; not DMP quaternion data.",
                    style: TextStyle(
                      color: Colors.white60,
                      fontSize: 11,
                    ),
                  ),
                  const Divider(),
                  if (raw == null)
                    const Text("Waiting for raw IMU notifications...")
                  else ...[
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        Chip(label: Text("Raw v${raw.version}")),
                        Chip(label: Text("Sequence ${raw.sequence}")),
                        Chip(label: Text("${raw.timestampMs} ms")),
                        if (raw.measuredRateHz != null)
                          Chip(label: Text("${raw.measuredRateHz} Hz")),
                        if (raw.flags.dmpActive)
                          const Chip(
                            avatar: Icon(Icons.sync, size: 16),
                            label: Text("DMP concurrently active"),
                          ),
                      ],
                    ),
                    if (!raw.flags.sampleValid)
                      const _RawWarning(
                        text: "Raw sample is marked invalid",
                      ),
                    if (raw.flags.magnetometerOverflow)
                      const _RawWarning(
                        text: "Magnetometer overflow",
                      ),
                    const SizedBox(height: 8),
                    Text(
                      "Accelerometer ${raw.accelerometerRange}",
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      raw.flags.accelerometerValid
                          ? "X ${raw.accelerometerXG.toStringAsFixed(4)} g   "
                              "Y ${raw.accelerometerYG.toStringAsFixed(4)} g   "
                              "Z ${raw.accelerometerZG.toStringAsFixed(4)} g"
                          : "Accelerometer data marked invalid",
                      style: TextStyle(
                        fontFamily: "monospace",
                        color: raw.flags.accelerometerValid
                            ? Colors.white
                            : Colors.amber,
                      ),
                    ),
                    Text(
                      "Counts: ${raw.accelerometerX}, "
                      "${raw.accelerometerY}, ${raw.accelerometerZ}",
                      style: const TextStyle(
                        color: Colors.white60,
                        fontFamily: "monospace",
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      "Gyroscope ${raw.gyroscopeRange}",
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      raw.flags.gyroscopeValid
                          ? "X ${raw.gyroscopeXDps.toStringAsFixed(3)} °/s   "
                              "Y ${raw.gyroscopeYDps.toStringAsFixed(3)} °/s   "
                              "Z ${raw.gyroscopeZDps.toStringAsFixed(3)} °/s"
                          : "Gyroscope data marked invalid",
                      style: TextStyle(
                        fontFamily: "monospace",
                        color: raw.flags.gyroscopeValid
                            ? Colors.white
                            : Colors.amber,
                      ),
                    ),
                    Text(
                      "Counts: ${raw.gyroscopeX}, "
                      "${raw.gyroscopeY}, ${raw.gyroscopeZ}",
                      style: const TextStyle(
                        color: Colors.white60,
                        fontFamily: "monospace",
                        fontSize: 11,
                      ),
                    ),
                    if (raw.version == 1) ...[
                      const SizedBox(height: 10),
                      const Text(
                        "Magnetometer",
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        raw.flags.magnetometerValid
                            ? "X ${raw.magnetometerX}   "
                                "Y ${raw.magnetometerY}   "
                                "Z ${raw.magnetometerZ} counts"
                            : "Magnetometer data marked invalid",
                        style: TextStyle(
                          fontFamily: "monospace",
                          color: raw.flags.magnetometerValid
                              ? Colors.white
                              : Colors.amber,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        raw.flags.temperatureValid
                            ? "Internal temperature: ${raw.temperature} counts"
                            : "Internal temperature data marked invalid",
                        style: TextStyle(
                          fontFamily: "monospace",
                          color: raw.flags.temperatureValid
                              ? Colors.white
                              : Colors.amber,
                        ),
                      ),
                    ],
                  ],
                  if (_invalidRawPacketCount > 0) ...[
                    const SizedBox(height: 8),
                    Text(
                      "Rejected raw packets: $_invalidRawPacketCount",
                      style: const TextStyle(
                        color: Colors.redAccent,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          Card(
            color: const Color.fromARGB(148, 93, 104, 134),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "BLE subscriptions",
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    "Disable unused streams to reduce BLE traffic and power use.",
                    style: TextStyle(color: Colors.white60, fontSize: 11),
                  ),
                  const Divider(),
                  // SwitchListTile(
                  //   contentPadding: EdgeInsets.zero,
                  //   title: const Text("IMU quaternion"),
                  //   subtitle: const Text(BleUuids.quaternionChar),
                  //   value: _enabledStreams["quaternion"]!,
                  //   onChanged: (value) => _toggleStream("quaternion", value),
                  // ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text("IMU raw"),
                    subtitle: const Text(BleUuids.rawImuChar),
                    value: _enabledStreams["rawImu"]!,
                    onChanged: (value) => _toggleStream("rawImu", value),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text("Auxiliary sensor"),
                    subtitle: const Text(BleUuids.auxiliaryChar),
                    value: _enabledStreams["auxiliary"]!,
                    onChanged: (value) => _toggleStream("auxiliary", value),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text("Device status"),
                    subtitle: const Text(BleUuids.statusChar),
                    value: _enabledStreams["status"]!,
                    onChanged: (value) => _toggleStream("status", value),
                  ),
                ],
              ),
            ),
          ),
          Card(
            color: const Color.fromARGB(255, 121, 138, 182),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "Raw data visualization",
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      for (final sensor in RawSensorType.values)
                        FilterChip(
                          label: Text(switch (sensor) {
                            RawSensorType.accelerometer => "Accelerometer (g)",
                            RawSensorType.gyroscope => "Gyroscope (°/s)",
                            RawSensorType.magnetometer => "Magnetometer (counts)",
                          }),
                          selected: _selectedRawSensors.contains(sensor),
                          onSelected: (selected) {
                            if (!selected && _selectedRawSensors.length == 1) return;
                            setState(() {
                              if (selected) {
                                _selectedRawSensors.add(sensor);
                              } else {
                                _selectedRawSensors.remove(sensor);
                              }
                            });
                          },
                        ),
                      DropdownButton<int>(
                        value: const [5, 10, 30]
                                .contains(_rawChartPeriod.inSeconds)
                            ? _rawChartPeriod.inSeconds
                            : -1,
                        items: const [
                          DropdownMenuItem(value: 5, child: Text("Last 5 s")),
                          DropdownMenuItem(value: 10, child: Text("Last 10 s")),
                          DropdownMenuItem(value: 30, child: Text("Last 30 s")),
                          DropdownMenuItem(value: -1, child: Text("Custom")),
                        ],
                        onChanged: (value) {
                          if (value == null) return;

                          if (value == -1) {
                            _selectCustomPeriod(
                              current: _rawChartPeriod,
                              onSelected: (period) {
                                setState(() => _rawChartPeriod = period);
                              },
                            );
                          } else {
                            setState(
                              () => _rawChartPeriod = Duration(seconds: value),
                            );
                          }
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Wrap(
                    spacing: 12,
                    children: [
                      _AxisLegend(color: Colors.redAccent, label: "X"),
                      _AxisLegend(color: Colors.greenAccent, label: "Y"),
                      _AxisLegend(color: Colors.lightBlueAccent, label: "Z"),
                    ],
                  ),
                  for (final sensor in RawSensorType.values)
                    if (_selectedRawSensors.contains(sensor)) ...[
                      Text(switch (sensor) {
                        RawSensorType.accelerometer => "Accelerometer (g)",
                        RawSensorType.gyroscope => "Gyroscope (°/s)",
                        RawSensorType.magnetometer => "Magnetometer (counts)",
                      }),
                      RawImuChart(
                        history: _rawHistory,
                        sensor: sensor,
                        visiblePeriod: _rawChartPeriod,
                      ),
                    ],
                  OutlinedButton.icon(
                    onPressed: _rawHistory.isEmpty ? null : _saveRawBufferCsv,
                    icon: const Icon(Icons.download),
                    label: Text("Save buffer CSV (${_rawHistory.length} samples)"),
                  ),
                  const Divider(),
                  const Text(
                    "CSV recording",
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      DropdownButton<int>(
                        value: const [5, 10, 30]
                                .contains(_rawRecordingPeriod.inSeconds)
                            ? _rawRecordingPeriod.inSeconds
                            : -1,
                        items: const [
                          DropdownMenuItem(value: 5, child: Text("5 seconds")),
                          DropdownMenuItem(value: 10, child: Text("10 seconds")),
                          DropdownMenuItem(value: 30, child: Text("30 seconds")),
                          DropdownMenuItem(value: -1, child: Text("Custom")),
                        ],
                        onChanged: _recordingRawCsv
                            ? null
                            : (value) {
                                if (value == null) return;

                                if (value == -1) {
                                  _selectCustomPeriod(
                                    current: _rawRecordingPeriod,
                                    onSelected: (period) {
                                      setState(
                                        () => _rawRecordingPeriod = period,
                                      );
                                    },
                                  );
                                } else {
                                  setState(
                                    () => _rawRecordingPeriod =
                                        Duration(seconds: value),
                                  );
                                }
                              },
                      ),
                      FilledButton.icon(
                        onPressed: _recordingRawCsv ||
                                _connectedDevice == null ||
                                !_enabledStreams["rawImu"]!
                            ? null
                            : _startRawCsvRecording,
                        icon: const Icon(Icons.fiber_manual_record),
                        label: const Text("Record CSV"),
                      ),
                      if (_recordingRawCsv)
                        OutlinedButton.icon(
                          onPressed: _cancelRawCsvRecording,
                          icon: const Icon(Icons.stop),
                          label: const Text("Cancel"),
                        ),
                    ],
                  ),
                  if (_recordingRawCsv) ...[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: _rawRecordingStartedAt == null
                          ? null
                          : (DateTime.now()
                                      .difference(_rawRecordingStartedAt!)
                                      .inMilliseconds /
                                  _rawRecordingPeriod.inMilliseconds)
                              .clamp(0.0, 1.0),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "Recording ${_rawRecording.length} samples...",
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                  ],
                ],
              ),
            ),
          ),
          ControlPanel(
            onSendCommand: _sendCommand,
            commandHistory: _commandHistory,
            initialRateHz: _isMacChrome && _enabledStreams["rawImu"] == true
                ? 10
                : 100,
          ),
        ],
      );

      return isWide
          ? Row(
              children: [
                // Expanded(flex: 3, child: visualizationColumn),
                Expanded(flex: 2, child: statusAndControlsColumn),
              ],
            )
          : Column(
              children: [
                // Expanded(flex: 6, child: visualizationColumn),
                Expanded(flex: 4, child: statusAndControlsColumn),
              ],
            );
    });
  }

  void _startRawCsvRecording() {
    if (_recordingRawCsv || !_enabledStreams["rawImu"]!) return;

    _rawRecordingTimer?.cancel();

    setState(() {
      _recordingRawCsv = true;
      _rawRecordingStartedAt = DateTime.now();
      _rawRecording.clear();
    });

    _rawRecordingTimer = Timer(
      _rawRecordingPeriod,
      _finishRawCsvRecording,
    );
  }

  Future<void> _finishRawCsvRecording() async {
    _rawRecordingTimer?.cancel();

    final samples = List<RawImuHistoryPoint>.from(_rawRecording);
    final startedAt = _rawRecordingStartedAt ?? DateTime.now();

    if (mounted) {
      setState(() {
        _recordingRawCsv = false;
        _rawRecordingStartedAt = null;
        _rawRecording.clear();
      });
    }

    if (samples.isEmpty) return;
    await _saveRawCsv(samples, startedAt, "raw_imu");
  }

  Future<void> _saveRawBufferCsv() async {
    final samples = List<RawImuHistoryPoint>.from(_rawHistory);
    if (samples.isEmpty) return;
    await _saveRawCsv(samples, samples.first.receivedAt, "raw_imu_buffer");
  }

  Future<void> _saveRawCsv(
    List<RawImuHistoryPoint> samples,
    DateTime startedAt,
    String prefix,
  ) async {

    final csv = StringBuffer()
      ..writeln(
        "received_iso8601,elapsed_ms,packet_version,sequence,"
        "sensor_timestamp_ms,flags,accel_range_code,gyro_range_code,"
        "accel_x_count,accel_y_count,accel_z_count,"
        "accel_x_g,accel_y_g,accel_z_g,"
        "gyro_x_count,gyro_y_count,gyro_z_count,"
        "gyro_x_dps,gyro_y_dps,gyro_z_dps,"
        "mag_x_count,mag_y_count,mag_z_count,"
        "temperature_count,measured_rate_hz",
      );

    for (final entry in samples) {
      final sample = entry.sample;
      final elapsedMs =
          entry.receivedAt.difference(startedAt).inMicroseconds / 1000.0;

      csv.writeln([
        entry.receivedAt.toUtc().toIso8601String(),
        elapsedMs.toStringAsFixed(3),
        sample.version,
        sample.sequence,
        sample.timestampMs,
        sample.flags.raw,
        sample.accelerometerRangeCode,
        sample.gyroscopeRangeCode,
        sample.accelerometerX,
        sample.accelerometerY,
        sample.accelerometerZ,
        sample.accelerometerXG,
        sample.accelerometerYG,
        sample.accelerometerZG,
        sample.gyroscopeX,
        sample.gyroscopeY,
        sample.gyroscopeZ,
        sample.gyroscopeXDps,
        sample.gyroscopeYDps,
        sample.gyroscopeZDps,
        sample.magnetometerX ?? "",
        sample.magnetometerY ?? "",
        sample.magnetometerZ ?? "",
        sample.temperature ?? "",
        sample.measuredRateHz ?? "",
      ].join(","));
    }

    final timestamp = startedAt
        .toUtc()
        .toIso8601String()
        .replaceAll(":", "-")
        .replaceAll(".", "-");

    try {
      final bytes = Uint8List.fromList(utf8.encode(csv.toString()));
      if (kIsWeb) {
        await FileSaver.instance.saveFile(
          name: "${prefix}_$timestamp",
          bytes: bytes,
          fileExtension: "csv",
          mimeType: MimeType.csv,
        );
      } else {
        await FileSaver.instance.saveAs(
          name: "${prefix}_$timestamp",
          bytes: bytes,
          fileExtension: "csv",
          mimeType: MimeType.csv,
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("CSV save failed: $error")),
        );
      }
    }
  }

  void _cancelRawCsvRecording() {
    _rawRecordingTimer?.cancel();

    setState(() {
      _recordingRawCsv = false;
      _rawRecordingStartedAt = null;
      _rawRecording.clear();
    });
  }

  Future<void> _selectCustomPeriod({
    required Duration current,
    required ValueChanged<Duration> onSelected,
  }) async {
    final controller = TextEditingController(
      text: current.inSeconds.toString(),
    );

    final seconds = await showDialog<int>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("Custom period"),
          content: TextField(
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: "Seconds",
              helperText: "1–600 seconds",
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancel"),
            ),
            FilledButton(
              onPressed: () {
                final value = int.tryParse(controller.text.trim());
                if (value == null || value < 1 || value > 600) return;
                Navigator.pop(context, value);
              },
              child: const Text("Apply"),
            ),
          ],
        );
      },
    );

    controller.dispose();

    if (seconds != null) {
      onSelected(Duration(seconds: seconds));
    }
  }
}

class _AxisLegend extends StatelessWidget {
  final Color color;
  final String label;

  const _AxisLegend({
    required this.color,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 3,
          color: color,
        ),
        const SizedBox(width: 4),
        Text(label),
      ],
    );
  }
}

class _RawWarning extends StatelessWidget {
  final String text;

  const _RawWarning({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.amber.shade900,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }
}
