import 'package:ble_imu_visualizer/models/frequency_history.dart';
import 'package:ble_imu_visualizer/models/frequency_recording_csv.dart';
import 'package:ble_imu_visualizer/models/imu_frequency_analysis.dart';
import 'package:ble_imu_visualizer/models/raw_imu_history.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('exports every band and preserves unavailable estimates and settings',
      () {
    final startedAt = DateTime.utc(2026, 11, 2);
    final point = FrequencyHistoryPoint(
      timestamp: startedAt.add(const Duration(milliseconds: 1250)),
      sensor: RawSensorType.accelerometer,
      analysis: const ImuFrequencyAnalysis(
        error: null,
        sampleRateHz: 25,
        nyquistHz: 12.5,
        duration: Duration(seconds: 8),
        sampleCount: 201,
        bands: [
          FrequencyBandResult(FrequencyBand('Percussion', 1, 5), 2.25, null),
          FrequencyBandResult(FrequencyBand('Vibration', 6.5, 10), null,
              'Too slow, collect "more" data'),
        ],
      ),
    );

    final csv = frequencyRecordingCsv([point], startedAt: startedAt);
    final lines = csv.trim().split('\n');
    expect(lines, hasLength(3));
    expect(lines.first, startsWith('estimate_time_utc,elapsed_ms,'));
    expect(lines[1],
        '2026-11-02T00:00:01.250Z,1250.0,accelerometer,8000,201,25.0,12.5,,Percussion,1.0,5.0,2.25,');
    expect(lines[2],
        '2026-11-02T00:00:01.250Z,1250.0,accelerometer,8000,201,25.0,12.5,,Vibration,6.5,10.0,,"Too slow, collect ""more"" data"');
  });

  test('records errors even if no band result is present', () {
    final now = DateTime.utc(2026, 11, 2);
    final point = FrequencyHistoryPoint(
      timestamp: now,
      sensor: RawSensorType.gyroscope,
      analysis: const ImuFrequencyAnalysis(
        error: 'Stream ended',
        sampleRateHz: null,
        nyquistHz: null,
        duration: Duration.zero,
        sampleCount: 0,
        bands: [],
      ),
    );
    final lines =
        frequencyRecordingCsv([point], startedAt: now).trim().split('\n');
    expect(lines, hasLength(2));
    expect(lines[1],
        '2026-11-02T00:00:00.000Z,0.0,gyroscope,0,0,,,Stream ended,,,,,Stream ended');
  });
}
