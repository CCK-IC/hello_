import "protocol.dart";

enum RawSensorType {
  accelerometer('Accelerometer', 'g'),
  gyroscope('Gyroscope', '°/s'),
  magnetometer('Magnetometer', 'counts');

  const RawSensorType(this.label, this.unit);

  final String label;
  final String unit;

  String get chartLabel => '$label ($unit)';
}

class RawImuHistoryPoint {
  final DateTime receivedAt;
  final RawImuSample sample;

  const RawImuHistoryPoint({
    required this.receivedAt,
    required this.sample,
  });

  List<double>? valuesFor(RawSensorType sensor) {
    switch (sensor) {
      case RawSensorType.accelerometer:
        if (!sample.flags.accelerometerValid) return null;
        return [
          sample.accelerometerXG,
          sample.accelerometerYG,
          sample.accelerometerZG,
        ];

      case RawSensorType.gyroscope:
        if (!sample.flags.gyroscopeValid) return null;
        return [
          sample.gyroscopeXDps,
          sample.gyroscopeYDps,
          sample.gyroscopeZDps,
        ];

      case RawSensorType.magnetometer:
        if (sample.version != 1 ||
            !sample.flags.magnetometerValid ||
            sample.magnetometerX == null ||
            sample.magnetometerY == null ||
            sample.magnetometerZ == null) {
          return null;
        }

        return [
          sample.magnetometerX!.toDouble(),
          sample.magnetometerY!.toDouble(),
          sample.magnetometerZ!.toDouble(),
        ];
    }
  }
}
