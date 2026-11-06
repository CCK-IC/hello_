import 'dart:async';
import 'dart:convert';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/frequency_history.dart';
import '../models/frequency_recording_csv.dart';
import '../models/imu_frequency_analysis.dart';
import '../models/raw_imu_history.dart';
import 'frequency_history_chart.dart';

/// Live, session-scoped analysis of one connected glove.
/// A null event clears the current session.
class ImuAnalysisPage extends StatefulWidget {
  const ImuAnalysisPage(
      {super.key, required this.samples, this.clock, this.saveCsv});

  final Stream<RawImuHistoryPoint?> samples;

  /// Optional clock for deterministic tests.
  final DateTime Function()? clock;

  /// Override CSV saving in tests.
  final Future<void> Function(String csv, DateTime startedAt, String prefix)?
      saveCsv;

  @override
  State<ImuAnalysisPage> createState() => _ImuAnalysisPageState();
}

class _ImuAnalysisPageState extends State<ImuAnalysisPage> {
  static const _staleAfter = Duration(seconds: 3);
  static const _retention = Duration(seconds: 12);
  static const _maxSamples = 4096;

  final _points = <RawImuHistoryPoint>[];
  final _frequencyHistory = FrequencyHistory();
  final _recordedFrequency = <FrequencyHistoryPoint>[];
  final Set<FrequencySeries> _selectedSeries = {
    FrequencySeries.percussion,
    FrequencySeries.vibration,
  };
  Duration _chartPeriod = const Duration(seconds: 10);
  Duration _recordingPeriod = const Duration(seconds: 10);
  DateTime? _recordingStartedAt;
  Timer? _recordingTimer;
  bool _recording = false;
  bool _saving = false;
  RawImuHistoryPoint? _lastLoggedSample;
  bool _gapLogged = false;
  RawSensorType _sensor = RawSensorType.accelerometer;
  final _lowerMin = TextEditingController(
      text: ImuFrequencyAnalyzer.defaultBands[0].minHz.toString());
  final _lowerMax = TextEditingController(
      text: ImuFrequencyAnalyzer.defaultBands[0].maxHz.toString());
  final _upperMin = TextEditingController(
      text: ImuFrequencyAnalyzer.defaultBands[1].minHz.toString());
  final _upperMax = TextEditingController(
      text: ImuFrequencyAnalyzer.defaultBands[1].maxHz.toString());
  late List<FrequencyBand> _bands;
  StreamSubscription<RawImuHistoryPoint?>? _subscription;
  Timer? _timer;
  DateTime? _lastArrival;
  ImuFrequencyAnalysis? _analysis;
  String? _bandError;
  bool _streamEnded = false;
  DateTime _now() => widget.clock?.call() ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    _bands = [
      FrequencyBand(
          'Percussion band',
          ImuFrequencyAnalyzer.defaultBands[0].minHz,
          ImuFrequencyAnalyzer.defaultBands[0].maxHz),
      FrequencyBand(
          'Vibration band',
          ImuFrequencyAnalyzer.defaultBands[1].minHz,
          ImuFrequencyAnalyzer.defaultBands[1].maxHz),
    ];
    _listen();
    _timer = Timer.periodic(
        const Duration(seconds: 1), (_) => _update(recordHistory: true));
  }

  @override
  void didUpdateWidget(covariant ImuAnalysisPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.samples != widget.samples) {
      _subscription?.cancel();
      _reset();
      _listen();
    }
  }

  void _listen() {
    _subscription = widget.samples.listen((point) {
      if (!mounted) return;
      if (point == null) {
        setState(_reset);
        return;
      }
      _streamEnded = false;
      _lastArrival = _now();
      _points.add(point);
      final cutoff = point.receivedAt.subtract(_retention);
      _points.removeWhere((p) => p.receivedAt.isBefore(cutoff));
      if (_points.length > _maxSamples) {
        _points.removeRange(0, _points.length - _maxSamples);
      }
    }, onDone: () {
      if (mounted) {
        setState(() {
          _reset();
          _streamEnded = true;
        });
      }
    }, onError: (Object error) {
      if (mounted) {
        setState(() {
          _reset();
          _streamEnded = true;
        });
      }
    });
  }

  void _reset() {
    if (_recording) {
      _appendGap('Connection ended.');
      _recordingTimer?.cancel();
      _recording = false;
    }
    _points.clear();
    _frequencyHistory.clear();
    _lastLoggedSample = null;
    _gapLogged = false;
    _lastArrival = null;
    _analysis = null;
    _streamEnded = false;
  }

  void _update({bool recordHistory = false}) {
    if (!mounted) return;
    final arrival = _lastArrival;
    if (arrival == null || _now().difference(arrival) >= _staleAfter) {
      if (_analysis != null || (arrival != null && _points.isNotEmpty)) {
        setState(() {
          if (recordHistory) _appendGap('Raw IMU data stopped.');
          _analysis = null;
          _points.clear();
          _lastLoggedSample = null;
        });
      }
      return;
    }
    final analysis = ImuFrequencyAnalyzer.analyze(
      _points,
      bands: _bands,
      sensor: _sensor,
    );
    setState(() {
      _analysis = analysis;
      if (recordHistory &&
          _points.isNotEmpty &&
          !identical(_lastLoggedSample, _points.last)) {
        _lastLoggedSample = _points.last;
        _gapLogged = false;
        _appendFrequency(FrequencyHistoryPoint(
            timestamp: _now(), sensor: _sensor, analysis: analysis));
      }
      _frequencyHistory.prune(_now());
    });
  }

  void _appendFrequency(FrequencyHistoryPoint point) {
    // A wall-clock correction starts a new display segment instead of
    // connecting estimates whose timestamps went backwards.
    if (_frequencyHistory.points.isNotEmpty &&
        point.timestamp.isBefore(_frequencyHistory.points.last.timestamp)) {
      _frequencyHistory.clear();
    }
    _frequencyHistory.add(point);
    if (_recording) _recordedFrequency.add(point);
  }

  void _appendGap(String reason) {
    if (_gapLogged) return;
    _gapLogged = true;
    _appendFrequency(FrequencyHistoryPoint(
      timestamp: _now(),
      sensor: _sensor,
      analysis: ImuFrequencyAnalysis(
        error: reason,
        sampleRateHz: null,
        nyquistHz: null,
        duration: Duration.zero,
        sampleCount: 0,
        bands: [
          for (final band in _bands) FrequencyBandResult(band, null, reason)
        ],
      ),
    ));
  }

  void _applyBands() {
    final values = [_lowerMin, _lowerMax, _upperMin, _upperMax]
        .map((controller) => double.tryParse(controller.text.trim()))
        .toList();
    if (values.any((value) => value == null || !value.isFinite) ||
        values[0]! <= 0 ||
        values[2]! <= 0 ||
        values[1]! <= values[0]! ||
        values[3]! <= values[2]!) {
      setState(() => _bandError =
          'Enter positive frequency ranges with the maximum greater than the minimum.');
      return;
    }
    setState(() {
      _bandError = null;
      _bands = [
        FrequencyBand('Percussion band', values[0]!, values[1]!),
        FrequencyBand('Vibration band', values[2]!, values[3]!),
      ];
      _analysis = null;
      _lastLoggedSample = null;
    });
    _update();
  }

  void _startRecording() {
    if (_recording) return;
    _recordingTimer?.cancel();
    setState(() {
      _recordedFrequency.clear();
      _recordingStartedAt = _now();
      _recording = true;
    });
    _recordingTimer = Timer(_recordingPeriod, _finishRecording);
  }

  Future<void> _finishRecording() async {
    _recordingTimer?.cancel();
    if (!mounted) return;
    setState(() => _recording = false);
    await _saveRecording();
  }

  Future<void> _saveRecording() async {
    if (_recordedFrequency.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No frequency estimates were recorded.')),
      );
      return;
    }
    await _saveFrequencyCsv(
        List.of(_recordedFrequency),
        _recordingStartedAt ?? _recordedFrequency.first.timestamp,
        'imu_frequency');
  }

  Future<void> _saveBuffer() async {
    _frequencyHistory.prune(_now());
    final points = List<FrequencyHistoryPoint>.of(_frequencyHistory.points);
    if (points.isEmpty) return;
    await _saveFrequencyCsv(
        points, points.first.timestamp, 'imu_frequency_buffer');
  }

  Future<void> _saveFrequencyCsv(List<FrequencyHistoryPoint> points,
      DateTime startedAt, String prefix) async {
    if (_saving) return;
    setState(() => _saving = true);
    final csv = frequencyRecordingCsv(points, startedAt: startedAt);
    try {
      final save = widget.saveCsv;
      if (save != null) {
        await save(csv, startedAt, prefix);
      } else {
        final timestamp = startedAt
            .toUtc()
            .toIso8601String()
            .replaceAll(':', '-')
            .replaceAll('.', '-');
        final bytes = Uint8List.fromList(utf8.encode(csv));
        if (kIsWeb) {
          await FileSaver.instance.saveFile(
              name: '${prefix}_$timestamp',
              bytes: bytes,
              fileExtension: 'csv',
              mimeType: MimeType.csv);
        } else {
          await FileSaver.instance.saveAs(
              name: '${prefix}_$timestamp',
              bytes: bytes,
              fileExtension: 'csv',
              mimeType: MimeType.csv);
        }
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('CSV save failed: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _selectCustomRecordingPeriod() async {
    final controller =
        TextEditingController(text: '${_recordingPeriod.inSeconds}');
    String? error;
    final seconds = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(builder: (context, updateDialog) {
        return AlertDialog(
          title: const Text('Recording duration'),
          content: TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
                labelText: 'Seconds (1–3600)', errorText: error),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () {
                  final value = int.tryParse(controller.text.trim());
                  if (value == null || value < 1 || value > 3600) {
                    updateDialog(
                        () => error = 'Enter a whole number from 1 to 3600.');
                  } else {
                    Navigator.pop(context, value);
                  }
                },
                child: const Text('Apply')),
          ],
        );
      }),
    );
    controller.dispose();
    if (mounted && seconds != null) {
      setState(() => _recordingPeriod = Duration(seconds: seconds));
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _recordingTimer?.cancel();
    _subscription?.cancel();
    _lowerMin.dispose();
    _lowerMax.dispose();
    _upperMin.dispose();
    _upperMax.dispose();
    super.dispose();
  }

  Widget _numberField(String label, TextEditingController controller) =>
      SizedBox(
        width: 120,
        child: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: label, suffixText: 'Hz'),
        ),
      );

  Widget _frequencyResults(ImuFrequencyAnalysis? analysis) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Candidate spectral peaks',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text(
                'A peak may reflect noise or a harmonic, rather than the movement frequency. Weak real signals may be suppressed. Verify against a reference measurement.'),
            const SizedBox(height: 12),
            LayoutBuilder(builder: (context, constraints) {
              const gap = 12.0;
              final width = constraints.maxWidth >= 520
                  ? (constraints.maxWidth - gap) / 2
                  : constraints.maxWidth;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (var i = 0; i < _bands.length; i++)
                    Builder(builder: (context) {
                      final result =
                          analysis != null && i < analysis.bands.length
                              ? analysis.bands[i]
                              : null;
                      final band = result?.band ?? _bands[i];
                      final peak = result?.peakHz;
                      return SizedBox(
                        key: ValueKey('frequency-result-$i'),
                        width: width,
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary.withAlpha(18),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(band.label,
                                  style: theme.textTheme.titleSmall),
                              Text('${band.minHz}–${band.maxHz} Hz',
                                  style: theme.textTheme.bodySmall),
                              const SizedBox(height: 8),
                              Text(
                                  peak == null
                                      ? '—'
                                      : '${peak.toStringAsFixed(2)} Hz',
                                  style: theme.textTheme.headlineMedium
                                      ?.copyWith(fontWeight: FontWeight.bold)),
                              const SizedBox(height: 4),
                              Text(
                                  peak == null
                                      ? result?.unavailableReason ??
                                          analysis?.error ??
                                          'Waiting for reliable samples.'
                                      : 'Candidate estimate',
                                  style: theme.textTheme.bodySmall),
                            ],
                          ),
                        ),
                      );
                    }),
                ],
              );
            }),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final arrival = _lastArrival;
    final stale = arrival != null && _now().difference(arrival) >= _staleAfter;
    final analysis = stale ? null : _analysis;

    return PopScope(
      canPop: !_recording,
      child: Scaffold(
        appBar: AppBar(title: const Text('IMU frequency analysis')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Single glove · live IMU',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text(
                'Explore periodic motion in the selected IMU signal. Peaks are estimates, not a clinical assessment.'),
            const SizedBox(height: 16),
            Wrap(spacing: 8, children: [
              for (final choice in const [
                (RawSensorType.accelerometer, 'Acceleration'),
                (RawSensorType.gyroscope, 'Angular velocity'),
              ])
                ChoiceChip(
                  label: Text(choice.$2),
                  selected: _sensor == choice.$1,
                  onSelected: (_) {
                    setState(() {
                      _sensor = choice.$1;
                      _analysis = null;
                      _lastLoggedSample = null;
                    });
                    _update();
                  },
                ),
            ]),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Live signal',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      if (_streamEnded)
                        const Text(
                            'Stream ended. Reconnect the glove to continue.')
                      else if (arrival == null)
                        const Text('Waiting for raw IMU data from this glove.')
                      else if (stale)
                        const Text(
                            'Raw IMU data stopped. Waiting for fresh samples.')
                      else if (analysis == null)
                        const Text('Collecting samples for analysis…')
                      else ...[
                        if (analysis.error != null) Text(analysis.error!),
                        if (analysis.sampleRateHz != null)
                          Text(
                              'Observed sample rate: ${analysis.sampleRateHz!.toStringAsFixed(1)} Hz'),
                        if (analysis.nyquistHz != null)
                          Text(
                              'Nyquist limit: ${analysis.nyquistHz!.toStringAsFixed(1)} Hz'),
                        Text(
                            'Window: ${(analysis.duration.inMilliseconds / 1000).toStringAsFixed(1)} s · ${analysis.sampleCount} samples'),
                      ],
                      const SizedBox(height: 8),
                      const Text(
                          'The Nyquist limit is only an upper bound. Motion above it can alias into lower frequencies unless filtered before sampling.'),
                    ]),
              ),
            ),
            const SizedBox(height: 12),
            _frequencyResults(analysis),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Frequency bands',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      const Text(
                          'These ranges are exploratory placeholders, not validated definitions. Adjust them for your experiment.'),
                      const SizedBox(height: 12),
                      Wrap(spacing: 16, runSpacing: 12, children: [
                        _numberField('Percussion min', _lowerMin),
                        _numberField('Percussion max', _lowerMax),
                        _numberField('Vibration min', _upperMin),
                        _numberField('Vibration max', _upperMax),
                      ]),
                      if (_bandError != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(_bandError!,
                              style: TextStyle(
                                  color: Theme.of(context).colorScheme.error)),
                        ),
                      const SizedBox(height: 12),
                      OutlinedButton(
                          onPressed: _applyBands,
                          child: const Text('Apply bands')),
                    ]),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Frequency history',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    const Text(
                        'Each point is a candidate peak from an overlapping 8-second analysis window, updated at most once per second. Gaps mean no reliable estimate.'),
                    const Text(
                        'History is kept while this page is open and clears on disconnect. Lines also break when the sensor or band settings change.'),
                    Wrap(spacing: 8, runSpacing: 4, children: [
                      for (final series in FrequencySeries.values)
                        FilterChip(
                          label: Text(series == FrequencySeries.percussion
                              ? 'Percussion band'
                              : 'Vibration band'),
                          avatar: CircleAvatar(
                              backgroundColor:
                                  FrequencyHistoryChart.colors[series],
                              radius: 6),
                          selected: _selectedSeries.contains(series),
                          onSelected: (selected) => setState(() {
                            if (selected) {
                              _selectedSeries.add(series);
                            } else {
                              _selectedSeries.remove(series);
                            }
                          }),
                        ),
                    ]),
                    Wrap(
                        spacing: 16,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          const Text('Display window'),
                          DropdownButton<int>(
                            value: _chartPeriod.inSeconds,
                            items: const [
                              DropdownMenuItem(
                                  value: 10, child: Text('10 seconds')),
                              DropdownMenuItem(
                                  value: 30, child: Text('30 seconds')),
                              DropdownMenuItem(
                                  value: 60, child: Text('1 minute')),
                              DropdownMenuItem(
                                  value: 300, child: Text('5 minutes')),
                            ],
                            onChanged: (seconds) {
                              if (seconds != null) {
                                setState(() =>
                                    _chartPeriod = Duration(seconds: seconds));
                              }
                            },
                          ),
                          const Text('History buffer'),
                          DropdownButton<int>(
                            value: _frequencyHistory.retention.inMinutes,
                            items: const [
                              DropdownMenuItem(
                                  value: 1, child: Text('1 minute')),
                              DropdownMenuItem(
                                  value: 5, child: Text('5 minutes')),
                              DropdownMenuItem(
                                  value: 10, child: Text('10 minutes')),
                              DropdownMenuItem(
                                  value: 30, child: Text('30 minutes')),
                              DropdownMenuItem(
                                  value: 60, child: Text('60 minutes')),
                            ],
                            onChanged: (minutes) {
                              if (minutes != null) {
                                setState(() => _frequencyHistory.setRetention(
                                    Duration(minutes: minutes), _now()));
                              }
                            },
                          ),
                        ]),
                    FrequencyHistoryChart(
                      history: _frequencyHistory.points,
                      visiblePeriod: _chartPeriod,
                      selected: _selectedSeries,
                      now: _now(),
                    ),
                    OutlinedButton.icon(
                      onPressed: _frequencyHistory.points.isEmpty || _saving
                          ? null
                          : _saveBuffer,
                      icon: const Icon(Icons.download),
                      label: Text(
                          'Save buffer CSV (${_frequencyHistory.points.length} estimates)'),
                    ),
                    const Divider(),
                    const Text('CSV recording',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    Wrap(
                        spacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          DropdownButton<int>(
                            value: const [5, 10, 30]
                                    .contains(_recordingPeriod.inSeconds)
                                ? _recordingPeriod.inSeconds
                                : -1,
                            items: const [
                              DropdownMenuItem(
                                  value: 5, child: Text('5 seconds')),
                              DropdownMenuItem(
                                  value: 10, child: Text('10 seconds')),
                              DropdownMenuItem(
                                  value: 30, child: Text('30 seconds')),
                              DropdownMenuItem(
                                  value: -1, child: Text('Custom')),
                            ],
                            onChanged: _recording
                                ? null
                                : (value) {
                                    if (value == -1) {
                                      _selectCustomRecordingPeriod();
                                    } else if (value != null) {
                                      setState(() => _recordingPeriod =
                                          Duration(seconds: value));
                                    }
                                  },
                          ),
                          if (!_recording)
                            FilledButton.icon(
                              onPressed: arrival == null ||
                                      stale ||
                                      _streamEnded ||
                                      _saving
                                  ? null
                                  : _startRecording,
                              icon: const Icon(Icons.fiber_manual_record),
                              label: const Text('Record CSV'),
                            )
                          else ...[
                            FilledButton.icon(
                                onPressed: _finishRecording,
                                icon: const Icon(Icons.stop),
                                label: const Text('Stop and save')),
                            OutlinedButton(
                                onPressed: () {
                                  _recordingTimer?.cancel();
                                  setState(() {
                                    _recording = false;
                                    _recordingStartedAt = null;
                                    _recordedFrequency.clear();
                                  });
                                },
                                child: const Text('Cancel')),
                          ],
                          if (!_recording && _recordedFrequency.isNotEmpty)
                            OutlinedButton(
                                onPressed: _saving ? null : _saveRecording,
                                child: const Text('Save recording CSV')),
                        ]),
                    if (_recording) ...[
                      Text('Recording ${_recordedFrequency.length} estimates…'),
                      const Text(
                          'Stop and save or cancel before leaving this page.'),
                    ],
                    if (!_recording && _recordedFrequency.isNotEmpty)
                      const Text(
                          'Recording retained on this page; save it before leaving.'),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
