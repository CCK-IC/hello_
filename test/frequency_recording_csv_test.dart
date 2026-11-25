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
    final first = lines[1].split(',');
    expect(first[0], '2026-11-02T00:00:01.250Z');
    expect(first[2], 'accelerometer');
    expect([1, 3, 4, 5, 6, 9, 10, 11].map((i) => num.parse(first[i])),
        [1250, 8000, 201, 25, 12.5, 1, 5, 2.25]);
    expect([first[7], first[8], first[12]], ['', 'Percussion', '']);
    final second = lines[2].split(',');
    expect(second.take(8), first.take(8));
    expect(second[8], 'Vibration');
    expect(second.sublist(9, 11).map(num.parse), [6.5, 10]);
    expect(second[11], isEmpty);
    expect(lines[2], endsWith('"Too slow, collect ""more"" data"'));
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
    final fields = lines[1].split(',');
    expect(fields[0], '2026-11-02T00:00:00.000Z');
    expect(num.parse(fields[1]), 0);
    expect(fields.skip(2).join(','),
        'gyroscope,0,0,,,Stream ended,,,,,Stream ended');
  });

  test('distinguishes ADC and fused rows by the input channel', () {
    const percussion =
        FrequencyBandResult(FrequencyBand('Percussion', 1, 5), 2, null);
    const vibration =
        FrequencyBandResult(FrequencyBand('Vibration', 6.5, 10), 8, null);
    ImuFrequencyAnalysis analysis(List<FrequencyBandResult> bands) =>
        ImuFrequencyAnalysis(
          error: null,
          sampleRateHz: 50,
          nyquistHz: 25,
          duration: const Duration(seconds: 6),
          sampleCount: 301,
          bands: bands,
        );
    final start = DateTime.utc(2026, 11, 24);
    final csv = frequencyRecordingCsv([
      FrequencyHistoryPoint(
        timestamp: start,
        sensor: RawSensorType.gyroscope,
        analysis: analysis([percussion, vibration]),
        adc: analysis([percussion]),
        fused: analysis([percussion, vibration]),
        adcChannel: 2,
      ),
    ], startedAt: start);
    final rows = csv.trim().split('\n').skip(1).map((row) => row.split(','));
    expect(rows.map((row) => (row[2], row[8], num.parse(row[11]))), [
      ('gyroscope', 'Percussion', 2),
      ('gyroscope', 'Vibration', 8),
      ('adc_ch_3', 'Percussion', 2),
      ('fused_gyroscope_adc_ch_3', 'Percussion', 2),
      ('fused_gyroscope_adc_ch_3', 'Vibration', 8),
    ]);
  });
}
