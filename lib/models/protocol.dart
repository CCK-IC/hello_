import 'dart:math' as math;
import 'dart:typed_data';

class BleUuids {
  static const String imuService = "8f7c0001-4f54-4d55-8000-5849414f494d";
  static const String quaternionChar = "8f7c0002-4f54-4d55-8000-5849414f494d";

  static const String deviceStatusService = "8f7c0020-4f54-4d55-8000-5849414f494d";
  static const String statusChar = "8f7c0021-4f54-4d55-8000-5849414f494d";
  static const String controlChar = "8f7c0022-4f54-4d55-8000-5849414f494d";

  static const String batteryService = "0000180f-0000-1000-8000-00805f9b34fb";
  static const String batteryLevelChar = "00002a19-0000-1000-8000-00805f9b34fb";
}

/// Bit flags for Quaternion packets
class QuatFlags {
  final int raw;
  QuatFlags(this.raw);

  bool get isValid => (raw & 0x01) != 0;
  bool get isDmp => (raw & 0x02) != 0;
  bool get isSynthetic => (raw & 0x04) != 0;
  bool get isFifoReset => (raw & 0x08) != 0;
  bool get isDegraded => (raw & 0x10) != 0;
}

/// Normalized Quaternion & Derived Euler Angles (in degrees)
class QuaternionSample {
  final int version;
  final QuatFlags flags;
  final int sequence;
  final int timestampMs;
  final double w, x, y, z;
  final int accuracy;
  final int? requestedRate;
  final int? measuredRate;

  QuaternionSample({
    required this.version,
    required this.flags,
    required this.sequence,
    required this.timestampMs,
    required this.w,
    required this.x,
    required this.y,
    required this.z,
    required this.accuracy,
    this.requestedRate,
    this.measuredRate,
  });

  /// Euler angles in degrees
  double get roll {
    final sinrCosp = 2 * (w * x + y * z);
    final cosrCosp = 1 - 2 * (x * x + y * y);
    return math.atan2(sinrCosp, cosrCosp) * 180.0 / math.pi;
  }

  double get pitch {
    final sinp = 2 * (w * y - z * x);
    if (sinp.abs() >= 1) {
      return (sinp.sign * (math.pi / 2)) * 180.0 / math.pi;
    }
    return math.asin(sinp) * 180.0 / math.pi;
  }

  double get yaw {
    final sinyCosp = 2 * (w * z + x * y);
    final cosyCosp = 1 - 2 * (y * y + z * z);
    return math.atan2(sinyCosp, cosyCosp) * 180.0 / math.pi;
  }

  static QuaternionSample? decode(Uint8List bytes) {
    if (bytes.isEmpty) return null;
    final version = bytes[0];
    final bd = ByteData.sublistView(bytes);

    if (version == 1 && bytes.length >= 28) {
      // Full Quaternion v1 (28 bytes)
      final flags = QuatFlags(bytes[1]);
      final accuracy = bd.getUint16(2, Endian.little);
      final seq = bd.getUint32(4, Endian.little);
      final ts = bd.getUint32(8, Endian.little);

      const double q30Scale = 1073741824.0;
      final q0 = bd.getInt32(12, Endian.little) / q30Scale;
      final q1 = bd.getInt32(16, Endian.little) / q30Scale;
      final q2 = bd.getInt32(20, Endian.little) / q30Scale;
      final q3 = bd.getInt32(24, Endian.little) / q30Scale;

      return QuaternionSample(
        version: 1,
        flags: flags,
        accuracy: accuracy,
        sequence: seq,
        timestampMs: ts,
        w: q0,
        x: q1,
        y: q2,
        z: q3,
      );
    } else if (version == 2 && bytes.length >= 20) {
      // Compact Quaternion v2 (20 bytes)
      final flags = QuatFlags(bytes[1]);
      final seq = bd.getUint16(2, Endian.little);
      final ts = bd.getUint32(4, Endian.little);

      const double q14Scale = 16384.0;
      final q0 = bd.getInt16(8, Endian.little) / q14Scale;
      final q1 = bd.getInt16(10, Endian.little) / q14Scale;
      final q2 = bd.getInt16(12, Endian.little) / q14Scale;
      final q3 = bd.getInt16(14, Endian.little) / q14Scale;

      final accuracy = bd.getUint16(16, Endian.little);
      final reqRate = bd.getUint8(18);
      final measuredRate = bd.getUint8(19);

      return QuaternionSample(
        version: 2,
        flags: flags,
        sequence: seq,
        timestampMs: ts,
        w: q0,
        x: q1,
        y: q2,
        z: q3,
        accuracy: accuracy,
        requestedRate: reqRate,
        measuredRate: measuredRate,
      );
    }
    return null;
  }
}

/// Device Status Packet Data
class DeviceStatus {
  final int version;
  final String boardName;
  final int imuState; // 0=OFF, 1=INIT, 2=RUNNING, 3=DEGRADED, 4=ERROR, 5=SUSPENDED
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
      case 0: return "OFF";
      case 1: return "INITIALIZING";
      case 2: return "RUNNING";
      case 3: return "DEGRADED";
      case 4: return "ERROR";
      case 5: return "SUSPENDED";
      default: return "UNKNOWN ($imuState)";
    }
  }

  static DeviceStatus? decode(Uint8List bytes) {
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