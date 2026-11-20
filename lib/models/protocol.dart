import 'dart:typed_data';

class BleUuids {
  static const String imuService = "8f7c0001-4f54-4d55-8000-5849414f494d";
  static const String rawImuChar = "8f7c0099-4f54-4d55-8000-5849414f494d";

  static const String deviceStatusService =
      "8f7c0020-4f54-4d55-8000-5849414f494d";
  static const String statusChar = "8f7c0021-4f54-4d55-8000-5849414f494d";
  static const String controlChar = "8f7c0022-4f54-4d55-8000-5849414f494d";
  static const String auxiliaryService = "8f7c0010-4f54-4d55-8000-5849414f494d";
  static const String auxiliaryChar = "8f7c0011-4f54-4d55-8000-5849414f494d";
  static const String batteryService = "0000180f-0000-1000-8000-00805f9b34fb";
  static const String batteryLevelChar = "00002a19-0000-1000-8000-00805f9b34fb";
}

class RawImuFlags {
  final int raw;
  final int version;

  const RawImuFlags(this.raw, this.version);

  bool get sampleValid => (raw & 0x01) != 0;
  bool get accelerometerValid => (raw & 0x02) != 0;
  bool get gyroscopeValid => (raw & 0x04) != 0;

  bool get magnetometerValid =>
      (version == 1 || version == 3) && (raw & 0x08) != 0;
  bool get temperatureValid =>
      (version == 1 || version == 3) && (raw & 0x10) != 0;
  bool get magnetometerOverflow =>
      (version == 1 || version == 3) && (raw & 0x20) != 0;

  bool get dmpActive => version != 2 ? (raw & 0x40) != 0 : (raw & 0x08) != 0;
}

class RawImuSample {
  static const List<double> _accelerometerSensitivity = [
    16384.0,
    8192.0,
    4096.0,
    2048.0,
  ];

  static const List<double> _gyroscopeSensitivity = [
    131.0,
    65.5,
    32.8,
    16.4,
  ];

  final int version;
  final int gloveId;
  final RawImuFlags flags;
  final int accelerometerRangeCode;
  final int gyroscopeRangeCode;
  final int sequence;
  final int timestampMs;

  final int accelerometerX;
  final int accelerometerY;
  final int accelerometerZ;

  final int gyroscopeX;
  final int gyroscopeY;
  final int gyroscopeZ;

  final int? magnetometerX;
  final int? magnetometerY;
  final int? magnetometerZ;
  final int? temperature;
  final int? measuredRateHz;

  const RawImuSample({
    required this.version,
    required this.flags,
    this.gloveId = 0,
    required this.accelerometerRangeCode,
    required this.gyroscopeRangeCode,
    required this.sequence,
    required this.timestampMs,
    required this.accelerometerX,
    required this.accelerometerY,
    required this.accelerometerZ,
    required this.gyroscopeX,
    required this.gyroscopeY,
    required this.gyroscopeZ,
    this.magnetometerX,
    this.magnetometerY,
    this.magnetometerZ,
    this.temperature,
    this.measuredRateHz,
  });

  double get accelerometerSensitivity =>
      _accelerometerSensitivity[accelerometerRangeCode];

  double get gyroscopeSensitivity => _gyroscopeSensitivity[gyroscopeRangeCode];

  double get accelerometerXG => accelerometerX / accelerometerSensitivity;
  double get accelerometerYG => accelerometerY / accelerometerSensitivity;
  double get accelerometerZG => accelerometerZ / accelerometerSensitivity;

  double get gyroscopeXDps => gyroscopeX / gyroscopeSensitivity;
  double get gyroscopeYDps => gyroscopeY / gyroscopeSensitivity;
  double get gyroscopeZDps => gyroscopeZ / gyroscopeSensitivity;

  String get accelerometerRange {
    const values = ["±2 g", "±4 g", "±8 g", "±16 g"];
    return values[accelerometerRangeCode];
  }

  String get gyroscopeRange {
    const values = ["±250 dps", "±500 dps", "±1000 dps", "±2000 dps"];
    return values[gyroscopeRangeCode];
  }

  /// Wrap-aware comparison for packets of the same version.
  /// Timestamp is used if sequence values are equal.
  bool isNewerThan(RawImuSample previous) {
    final sequenceMask = version == 2 ? 0xFFFF : 0xFFFFFFFF;
    final halfRange = version == 2 ? 0x8000 : 0x80000000;

    final difference = (sequence - previous.sequence) & sequenceMask;
    if (difference != 0) {
      return difference < halfRange;
    }

    final timestampDifference =
        (timestampMs - previous.timestampMs) & 0xFFFFFFFF;
    return timestampDifference != 0 && timestampDifference < 0x80000000;
  }

  /// Latest local sample, after validating the entire notification atomically.
  static RawImuSample? decode(Uint8List bytes) {
    final samples = decodeAll(bytes);
    if (samples == null) return null;
    for (final sample in samples.reversed) {
      if (sample.gloveId == 0) return sample;
    }
    return null;
  }

  static List<RawImuSample>? decodeAll(Uint8List bytes) {
    if (bytes.isNotEmpty && bytes[0] == 3) {
      if (!isValidV3SensorFrame(bytes, kind: 1)) return null;
      final data = ByteData.sublistView(bytes);
      final samples = <RawImuSample>[];
      for (var row = 0; row < bytes[3]; row++) {
        for (var glove = 0; glove < 2; glove++) {
          if ((bytes[2] & (1 << glove)) == 0) continue;
          final meta = 4 + glove * 12;
          final offset = 28 + (row * 2 + glove) * 24;
          samples.add(RawImuSample(
            version: 3,
            gloveId: glove,
            flags: RawImuFlags(bytes[offset + 3], 3),
            accelerometerRangeCode: bytes[meta + 10] & 3,
            gyroscopeRangeCode: (bytes[meta + 10] >> 2) & 3,
            sequence: (data.getUint32(meta, Endian.little) + bytes[offset]) &
                0xffffffff,
            timestampMs: (data.getUint32(meta + 4, Endian.little) +
                    data.getUint16(offset + 1, Endian.little)) &
                0xffffffff,
            measuredRateHz: data.getUint16(meta + 8, Endian.little),
            accelerometerX: data.getInt16(offset + 4, Endian.little),
            accelerometerY: data.getInt16(offset + 6, Endian.little),
            accelerometerZ: data.getInt16(offset + 8, Endian.little),
            gyroscopeX: data.getInt16(offset + 10, Endian.little),
            gyroscopeY: data.getInt16(offset + 12, Endian.little),
            gyroscopeZ: data.getInt16(offset + 14, Endian.little),
            magnetometerX: data.getInt16(offset + 16, Endian.little),
            magnetometerY: data.getInt16(offset + 18, Endian.little),
            magnetometerZ: data.getInt16(offset + 20, Endian.little),
            temperature: data.getInt16(offset + 22, Endian.little),
          ));
        }
      }
      return samples;
    }
    final sample = _decodeLegacy(bytes);
    return sample == null ? null : [sample];
  }

  static RawImuSample? _decodeLegacy(Uint8List bytes) {
    if (bytes.isEmpty) return null;

    final version = bytes[0];

    if (version == 1) {
      if (bytes.length != 36) return null;

      final data = ByteData.sublistView(bytes);
      final rawFlags = data.getUint8(1);
      final accelerometerRangeCode = data.getUint8(2);
      final gyroscopeRangeCode = data.getUint8(3);

      // Bit 7 is reserved in Full Raw v1.
      if ((rawFlags & 0x80) != 0) return null;

      // Firmware currently defines only range codes 0 through 3.
      if (accelerometerRangeCode > 3 || gyroscopeRangeCode > 3) {
        return null;
      }

      // Reserved field must be zero for this protocol version.
      if (data.getUint16(34, Endian.little) != 0) return null;

      return RawImuSample(
        version: 1,
        flags: RawImuFlags(rawFlags, 1),
        accelerometerRangeCode: accelerometerRangeCode,
        gyroscopeRangeCode: gyroscopeRangeCode,
        sequence: data.getUint32(4, Endian.little),
        timestampMs: data.getUint32(8, Endian.little),
        accelerometerX: data.getInt16(12, Endian.little),
        accelerometerY: data.getInt16(14, Endian.little),
        accelerometerZ: data.getInt16(16, Endian.little),
        gyroscopeX: data.getInt16(18, Endian.little),
        gyroscopeY: data.getInt16(20, Endian.little),
        gyroscopeZ: data.getInt16(22, Endian.little),
        magnetometerX: data.getInt16(24, Endian.little),
        magnetometerY: data.getInt16(26, Endian.little),
        magnetometerZ: data.getInt16(28, Endian.little),
        temperature: data.getInt16(30, Endian.little),
        measuredRateHz: data.getUint16(32, Endian.little),
      );
    }

    if (version == 2) {
      if (bytes.length != 20) return null;

      final data = ByteData.sublistView(bytes);
      final rawFlags = data.getUint8(1);

      return RawImuSample(
        version: 2,
        flags: RawImuFlags(rawFlags, 2),
        accelerometerRangeCode: (rawFlags & 0x30) >> 4,
        gyroscopeRangeCode: (rawFlags & 0xC0) >> 6,
        sequence: data.getUint16(2, Endian.little),
        timestampMs: data.getUint32(4, Endian.little),
        accelerometerX: data.getInt16(8, Endian.little),
        accelerometerY: data.getInt16(10, Endian.little),
        accelerometerZ: data.getInt16(12, Endian.little),
        gyroscopeX: data.getInt16(14, Endian.little),
        gyroscopeY: data.getInt16(16, Endian.little),
        gyroscopeZ: data.getInt16(18, Endian.little),
      );
    }

    return null;
  }
}

/// Device Status Packet Data
class DeviceStatus {
  final int version;
  final int gloveId;
  final int bufferDroppedSamples;
  final int featureFlags;
  final int boardId;
  final int deviceFlags;
  final int phy;
  final int rawSamplesAcquired;
  final int lastError;
  final String boardName;
  final int
      imuState; // 0=OFF, 1=INIT, 2=RUNNING, 3=DEGRADED, 4=ERROR, 5=SUSPENDED
  final int uptimeMs;
  final int requestedRate;
  final int actualSensorRate;
  final int notificationRate;
  final int batteryMilliVolts;
  final int batteryPercent;
  final int attMtu;
  final int droppedNotifications;
  final int fifoRecoveries;
  final int i2cErrors;
  final int freeHeap;
  final String firmwareVersion;

  DeviceStatus({
    required this.version,
    required this.boardName,
    this.gloveId = 0,
    this.bufferDroppedSamples = 0,
    this.featureFlags = 0,
    this.boardId = 0,
    this.deviceFlags = 0,
    this.phy = 0,
    this.rawSamplesAcquired = 0,
    this.lastError = 0,
    required this.imuState,
    required this.uptimeMs,
    required this.requestedRate,
    required this.actualSensorRate,
    required this.notificationRate,
    required this.batteryMilliVolts,
    required this.batteryPercent,
    required this.attMtu,
    required this.droppedNotifications,
    required this.fifoRecoveries,
    required this.i2cErrors,
    this.freeHeap = 0,
    this.firmwareVersion = "Unknown",
  });

  String get imuStateString {
    switch (imuState) {
      case 0:
        return "OFF";
      case 1:
        return "INITIALIZING";
      case 2:
        return "RUNNING";
      case 3:
        return "DEGRADED";
      case 4:
        return "ERROR";
      case 5:
        return "SUSPENDED";
      default:
        return "UNKNOWN ($imuState)";
    }
  }

  static DeviceStatus? decode(Uint8List bytes) {
    final samples = decodeAll(bytes);
    if (samples == null) return null;
    for (final sample in samples.reversed) {
      if (sample.gloveId == 0) return sample;
    }
    return null;
  }

  static List<DeviceStatus>? decodeAll(Uint8List bytes) {
    if (bytes.isNotEmpty && bytes[0] == 3) {
      if (bytes.length != 108 ||
          bytes[1] != 4 ||
          !_validPresence(bytes[2]) ||
          bytes[3] != 1) {
        return null;
      }
      final data = ByteData.sublistView(bytes);
      // Validate both slots before returning either status.
      for (var glove = 0; glove < 2; glove++) {
        final offset = 4 + glove * 52;
        if ((bytes[2] & (1 << glove)) == 0) {
          if (!_allZero(bytes, offset, offset + 52)) return null;
        } else if (bytes[offset + 16] > 100 ||
            data.getUint16(offset + 22, Endian.little) != 3) {
          return null;
        }
      }
      return [
        for (var glove = 0; glove < 2; glove++)
          if ((bytes[2] & (1 << glove)) != 0) _decodeV3Slot(data, glove)
      ];
    }
    final status = _decodeLegacy(bytes);
    return status == null ? null : [status];
  }

  static DeviceStatus _decodeV3Slot(ByteData data, int glove) {
    final o = 4 + glove * 52;
    final board = data.getUint8(o + 14);
    return DeviceStatus(
      version: 3,
      gloveId: glove,
      boardId: board,
      boardName: board == 1
          ? 'XIAO ESP32-C3'
          : board == 2
              ? 'XIAO ESP32-S3'
              : 'Unknown ($board)',
      uptimeMs: data.getUint32(o, Endian.little),
      requestedRate: data.getUint16(o + 4, Endian.little),
      actualSensorRate: data.getUint16(o + 6, Endian.little),
      notificationRate: data.getUint16(o + 8, Endian.little),
      batteryMilliVolts: data.getUint16(o + 10, Endian.little),
      attMtu: data.getUint16(o + 12, Endian.little),
      imuState: data.getUint8(o + 15),
      batteryPercent: data.getUint8(o + 16),
      deviceFlags: data.getUint8(o + 17),
      firmwareVersion:
          '${data.getUint8(o + 18)}.${data.getUint8(o + 19)}.${data.getUint8(o + 20)}',
      phy: data.getUint8(o + 21),
      featureFlags: data.getUint16(o + 22, Endian.little),
      freeHeap: data.getUint32(o + 24, Endian.little),
      droppedNotifications: data.getUint32(o + 28, Endian.little),
      fifoRecoveries: data.getUint32(o + 32, Endian.little),
      i2cErrors: data.getUint32(o + 36, Endian.little),
      bufferDroppedSamples: data.getUint32(o + 40, Endian.little),
      rawSamplesAcquired: data.getUint32(o + 44, Endian.little),
      lastError: data.getInt32(o + 48, Endian.little),
    );
  }

  static DeviceStatus? _decodeLegacy(Uint8List bytes) {
    if (bytes.isEmpty) return null;
    final version = bytes[0];
    final bd = ByteData.sublistView(bytes);

    if (version == 1 && bytes.length >= 64) {
      // Full Status v1 (64 bytes)
      final boardId = bytes[1];
      final board = boardId == 1
          ? "XIAO ESP32-C3"
          : (boardId == 2 ? "XIAO ESP32-S3" : "Unknown ($boardId)");
      final imuState = bytes[3];
      final uptimeMs = bd.getUint32(4, Endian.little);
      final reqRate = bd.getUint16(8, Endian.little);
      final sensorRate = bd.getUint16(10, Endian.little);
      final notifRate = bd.getUint16(12, Endian.little);
      final battMv = bd.getUint16(16, Endian.little);
      final battPct = bd.getUint8(18).clamp(0, 100);
      final mtu = bd.getUint16(20, Endian.little);
      final freeHeap = bd.getUint32(24, Endian.little);
      final droppedNotif = bd.getUint32(40, Endian.little);
      final fifoRecoveries = bd.getUint32(44, Endian.little);
      final i2cErrors = bd.getUint32(48, Endian.little);
      final fwMajor = bytes[60];
      final fwMinor = bytes[61];
      final fwPatch = bytes[62];

      return DeviceStatus(
        version: 1,
        boardName: board,
        imuState: imuState,
        uptimeMs: uptimeMs,
        requestedRate: reqRate,
        actualSensorRate: sensorRate,
        notificationRate: notifRate,
        batteryMilliVolts: battMv,
        batteryPercent: battPct,
        attMtu: mtu,
        droppedNotifications: droppedNotif,
        fifoRecoveries: fifoRecoveries,
        i2cErrors: i2cErrors,
        freeHeap: freeHeap,
        firmwareVersion: "$fwMajor.$fwMinor.$fwPatch",
      );
    } else if (version == 2 && bytes.length >= 20) {
      // Compact Status v2 (20 bytes)
      final uptimeMs = bd.getUint32(2, Endian.little);
      final reqRate = bd.getUint16(6, Endian.little);
      final sensorRate = bd.getUint16(8, Endian.little);
      final notifRate = bd.getUint16(10, Endian.little);
      final battMv = bd.getUint16(12, Endian.little);
      final battPct = bd.getUint8(14).clamp(0, 100);
      final imuState = bd.getUint8(15);
      final mtu = bd.getUint16(16, Endian.little);
      final droppedNotif = bd.getUint8(18);
      final errors = bd.getUint8(19);

      return DeviceStatus(
        version: 2,
        boardName: "Generic/Compact",
        imuState: imuState,
        uptimeMs: uptimeMs,
        requestedRate: reqRate,
        actualSensorRate: sensorRate,
        notificationRate: notifRate,
        batteryMilliVolts: battMv,
        batteryPercent: battPct,
        attMtu: mtu,
        droppedNotifications: droppedNotif,
        fifoRecoveries: errors,
        i2cErrors: errors,
      );
    }
    return null;
  }
}

/// Typed Command Encoder
abstract class BleControlCommand {
  Uint8List serialize();
  String get name;
}

class SetRateCommand extends BleControlCommand {
  final int rateHz;
  SetRateCommand(this.rateHz) {
    if (rateHz < 1 || rateHz > 200) {
      throw RangeError.range(rateHz, 1, 200, "rateHz");
    }
  }
  @override
  String get name => "Set Rate ($rateHz Hz)";
  @override
  Uint8List serialize() {
    final b = ByteData(3);
    b.setUint8(0, 0x01);
    b.setUint16(1, rateHz, Endian.little);
    return b.buffer.asUint8List();
  }
}

class SetAdcRateCommand extends BleControlCommand {
  final int rateHz;
  SetAdcRateCommand(this.rateHz) {
    if (rateHz < 1 || rateHz > 200) {
      throw RangeError.range(rateHz, 1, 200, 'rateHz');
    }
  }

  @override
  String get name => 'Set ADC Rate ($rateHz Hz)';

  @override
  Uint8List serialize() {
    final bytes = ByteData(3)
      ..setUint8(0, 0x08)
      ..setUint16(1, rateHz, Endian.little);
    return bytes.buffer.asUint8List();
  }
}

class SetStatusPeriodCommand extends BleControlCommand {
  final int periodMs;
  SetStatusPeriodCommand(this.periodMs) {
    if (periodMs < 250 || periodMs > 60000) {
      throw RangeError.range(periodMs, 250, 60000, "periodMs");
    }
  }
  @override
  String get name => "Set Status Period ($periodMs ms)";
  @override
  Uint8List serialize() {
    final b = ByteData(3);
    b.setUint8(0, 0x02);
    b.setUint16(1, periodMs, Endian.little);
    return b.buffer.asUint8List();
  }
}

class SetSlowModeCommand extends BleControlCommand {
  final bool enable;
  SetSlowModeCommand(this.enable);
  @override
  String get name => "Set Slow Mode (${enable ? 'ON' : 'OFF'})";
  @override
  Uint8List serialize() => Uint8List.fromList([0x04, enable ? 0x01 : 0x00]);
}

class PowerOffCommand extends BleControlCommand {
  @override
  String get name => "Request Power-Off";
  @override
  Uint8List serialize() => Uint8List.fromList([0x05, 0xA5, 0x5A]);
}

class SensorRecoveryCommand extends BleControlCommand {
  @override
  String get name => "Request Sensor Recovery";
  @override
  Uint8List serialize() => Uint8List.fromList([0x06]);
}

bool _validPresence(int mask) => mask >= 1 && mask <= 3;

bool _allZero(Uint8List bytes, int start, int end) {
  for (var i = start; i < end; i++) {
    if (bytes[i] != 0) return false;
  }
  return true;
}

/// Shared structural validation for raw, quaternion and AUX v3 decoders.
/// No sample is constructed until the entire fixed-slot frame passes.
bool isValidV3SensorFrame(Uint8List bytes, {required int kind}) {
  final slotSize = switch (kind) { 1 => 24, 2 => 22, 3 => 20, _ => 0 };
  if (slotSize == 0 ||
      bytes.length < 28 ||
      bytes[0] != 3 ||
      bytes[1] != kind ||
      !_validPresence(bytes[2]) ||
      bytes[3] < 1 ||
      bytes[3] > 8 ||
      bytes.length != 28 + bytes[3] * 2 * slotSize) {
    return false;
  }
  final data = ByteData.sublistView(bytes);
  for (var glove = 0; glove < 2; glove++) {
    final meta = 4 + glove * 12;
    final present = (bytes[2] & (1 << glove)) != 0;
    final format = bytes[meta + 10];
    if (!present) {
      if (!_allZero(bytes, meta, meta + 12)) return false;
    } else {
      if (bytes[meta + 11] != 0) return false;
      if (kind == 1 && (format & 0xf0) != 0) return false;
      if (kind == 2 && format != 0) return false;
      if (kind == 3 && (format < 1 || format > 8)) return false;
    }
    var previousSequenceDelta = -1;
    var previousTimeDelta = -1;
    for (var row = 0; row < bytes[3]; row++) {
      final o = 28 + (row * 2 + glove) * slotSize;
      if (!present) {
        if (!_allZero(bytes, o, o + slotSize)) return false;
        continue;
      }
      final sequenceDelta = bytes[o];
      final timeDelta = data.getUint16(o + 1, Endian.little);
      if (row == 0 && (sequenceDelta != 0 || timeDelta != 0)) return false;
      if (sequenceDelta <= previousSequenceDelta ||
          timeDelta < previousTimeDelta) {
        return false;
      }
      previousSequenceDelta = sequenceDelta;
      previousTimeDelta = timeDelta;
      final flagMask = switch (kind) { 1 => 0x7f, 2 => 0x1f, _ => 1 };
      if ((bytes[o + 3] & ~flagMask) != 0) return false;
      if (kind == 3 && !_allZero(bytes, o + 4 + format * 2, o + slotSize)) {
        return false;
      }
    }
  }
  return true;
}

/// Full Q30 quaternion records. Flags use full-v1 meanings, never raw flags.
class QuaternionSample {
  final int version;
  final int gloveId;
  final int sequence;
  final int timestampMs;
  final int flags;
  final int q0Q30;
  final int q1Q30;
  final int q2Q30;
  final int q3Q30;
  final int accuracy;
  final int measuredRateHz;

  const QuaternionSample({
    this.version = 3,
    this.gloveId = 0,
    required this.sequence,
    required this.timestampMs,
    required this.flags,
    required this.q0Q30,
    required this.q1Q30,
    required this.q2Q30,
    required this.q3Q30,
    required this.accuracy,
    required this.measuredRateHz,
  });

  bool get sampleValid => (flags & 1) != 0;
  bool get dmpActive => (flags & 2) != 0;
  bool get synthetic => (flags & 4) != 0;
  bool get fifoReset => (flags & 8) != 0;
  bool get degraded => (flags & 16) != 0;
  double get q0 => q0Q30 / 1073741824.0;
  double get q1 => q1Q30 / 1073741824.0;
  double get q2 => q2Q30 / 1073741824.0;
  double get q3 => q3Q30 / 1073741824.0;

  static List<QuaternionSample>? decodeAll(Uint8List bytes) {
    if (!isValidV3SensorFrame(bytes, kind: 2)) return null;
    final data = ByteData.sublistView(bytes);
    return [
      for (var row = 0; row < bytes[3]; row++)
        for (var glove = 0; glove < 2; glove++)
          if ((bytes[2] & (1 << glove)) != 0) _decodeSlot(data, row, glove)
    ];
  }

  static QuaternionSample _decodeSlot(ByteData data, int row, int glove) {
    final meta = 4 + glove * 12;
    final o = 28 + (row * 2 + glove) * 22;
    return QuaternionSample(
      gloveId: glove,
      sequence:
          (data.getUint32(meta, Endian.little) + data.getUint8(o)) & 0xffffffff,
      timestampMs: (data.getUint32(meta + 4, Endian.little) +
              data.getUint16(o + 1, Endian.little)) &
          0xffffffff,
      measuredRateHz: data.getUint16(meta + 8, Endian.little),
      flags: data.getUint8(o + 3),
      q0Q30: data.getInt32(o + 4, Endian.little),
      q1Q30: data.getInt32(o + 8, Endian.little),
      q2Q30: data.getInt32(o + 12, Endian.little),
      q3Q30: data.getInt32(o + 16, Endian.little),
      accuracy: data.getUint16(o + 20, Endian.little),
    );
  }
}
