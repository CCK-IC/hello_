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
    var input = '${_recordingPeriod.inSeconds}';
    String? error;
    final seconds = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(builder: (context, updateDialog) {
        return AlertDialog(
          title: const Text('Recording duration'),
          scrollable: true,
          content: TextFormField(
            initialValue: input,
            onChanged: (value) => input = value,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: 'Seconds (1–3600)',
              errorText: error,
              errorMaxLines: 4,
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () {
                  final value = int.tryParse(input.trim());
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
      TextField(
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          border: const OutlineInputBorder(),
          floatingLabelBehavior: FloatingLabelBehavior.always,
          labelText: label,
          suffixText: 'Hz',
        ),
      );

  Widget _liveSignal({
    required bool hasArrival,
    required bool stale,
    required ImuFrequencyAnalysis? analysis,
  }) {
    final status = switch ((_streamEnded, hasArrival, stale, analysis)) {
      (true, _, _, _) => 'Stream ended. Reconnect the glove to continue.',
      (_, false, _, _) => 'Waiting for raw IMU data from this glove.',
      (_, _, true, _) => 'Raw IMU data stopped. Waiting for fresh samples.',
      (_, _, _, null) => 'Collecting samples for analysis…',
      (_, _, _, final result?) => result.error ?? 'Receiving raw IMU data.',
    };
    return _AnalysisSection(
      title: 'Live signal',
      children: [
        Semantics(
          container: true,
          liveRegion: true,
          child: Text(status, style: Theme.of(context).textTheme.titleSmall),
        ),
        if (analysis != null) ...[
          if (analysis.sampleRateHz != null)
            Text(
                'Observed sample rate: ${analysis.sampleRateHz!.toStringAsFixed(1)} Hz'),
          if (analysis.nyquistHz != null)
            Text('Nyquist limit: ${analysis.nyquistHz!.toStringAsFixed(1)} Hz'),
          Text(
              'Window: ${(analysis.duration.inMilliseconds / 1000).toStringAsFixed(1)} s · ${analysis.sampleCount} samples'),
        ],
        const SizedBox(height: 8),
        const Text(
            'The Nyquist limit is only an upper bound. Motion above it can alias into lower frequencies unless filtered before sampling.'),
      ],
    );
  }

  Widget _frequencyResults(ImuFrequencyAnalysis? analysis) {
    return _AnalysisSection(
      title: 'Candidate spectral peaks',
      children: [
        const Text(
            'A peak may reflect noise or a harmonic, rather than the movement frequency. Weak real signals may be suppressed. Verify against a reference measurement.'),
        const SizedBox(height: 12),
        _ControlGrid(
          minWidth: 254,
          maxColumns: 2,
          children: [
            for (var i = 0; i < _bands.length; i++)
              _frequencyResult(analysis, i),
          ],
        ),
      ],
    );
  }

  Widget _frequencyResult(ImuFrequencyAnalysis? analysis, int index) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final result = analysis != null && index < analysis.bands.length
        ? analysis.bands[index]
        : null;
    final band = result?.band ?? _bands[index];
    final peak = result?.peakHz;
    return Container(
      key: ValueKey('frequency-result-$index'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(band.label, style: theme.textTheme.titleSmall),
          Text('${band.minHz}–${band.maxHz} Hz',
              style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          ExcludeSemantics(
            excluding: peak == null,
            child: Text(
              peak == null ? '—' : '${peak.toStringAsFixed(2)} Hz',
              style: theme.textTheme.headlineMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            peak == null
                ? result?.unavailableReason ??
                    analysis?.error ??
                    'Waiting for reliable samples.'
                : 'Candidate estimate',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _bandSettings() {
    return _AnalysisSection(
      title: 'Frequency bands',
      children: [
        const Text(
            'These ranges are exploratory placeholders, not validated definitions. Adjust them for your experiment.'),
        const SizedBox(height: 16),
        _ControlGrid(
          minWidth: 170,
          maxColumns: 4,
          children: [
            _numberField('Percussion min', _lowerMin),
            _numberField('Percussion max', _lowerMax),
            _numberField('Vibration min', _upperMin),
            _numberField('Vibration max', _upperMax),
          ],
        ),
        if (_bandError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Semantics(
              container: true,
              liveRegion: true,
              child: Text(
                _bandError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ),
        const SizedBox(height: 12),
        OutlinedButton(
            onPressed: _applyBands, child: const Text('Apply bands')),
      ],
    );
  }

  Widget _historySection() {
    final scheme = Theme.of(context).colorScheme;
    final history = _frequencyHistory.points;
    return _AnalysisSection(
      title: 'Frequency history',
      children: [
        const Text(
            'Each point is a candidate peak from an overlapping 8-second analysis window, updated at most once per second. Gaps mean no reliable estimate.'),
        const SizedBox(height: 8),
        const Text(
            'History is kept while this page is open and clears on disconnect. Lines also break when the sensor or band settings change.'),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final series in FrequencySeries.values)
              FilterChip(
                label: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(series.marker, size: 12, color: series.color(scheme)),
                    const SizedBox(width: 6),
                    Flexible(child: Text(series.label)),
                  ],
                ),
                selected: _selectedSeries.contains(series),
                onSelected: (selected) => setState(() {
                  if (selected) {
                    _selectedSeries.add(series);
                  } else {
                    _selectedSeries.remove(series);
                  }
                }),
              ),
          ],
        ),
        const SizedBox(height: 12),
        _ControlGrid(
          minWidth: 192,
          maxColumns: 2,
          children: [
            _DurationSelect(
              label: 'Display window',
              value: _chartPeriod.inSeconds,
              options: const {
                10: '10 seconds',
                30: '30 seconds',
                60: '1 minute',
                300: '5 minutes',
              },
              onChanged: (seconds) {
                if (seconds != null) {
                  setState(() => _chartPeriod = Duration(seconds: seconds));
                }
              },
            ),
            _DurationSelect(
              label: 'History buffer',
              value: _frequencyHistory.retention.inMinutes,
              options: const {
                1: '1 minute',
                5: '5 minutes',
                10: '10 minutes',
                30: '30 minutes',
                60: '60 minutes',
              },
              onChanged: (minutes) {
                if (minutes != null) {
                  setState(() => _frequencyHistory.setRetention(
                      Duration(minutes: minutes), _now()));
                }
              },
            ),
          ],
        ),
        const SizedBox(height: 12),
        FrequencyHistoryChart(
          history: history,
          visiblePeriod: _chartPeriod,
          selected: _selectedSeries,
          now: _now(),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: history.isEmpty || _saving ? null : _saveBuffer,
          icon: const Icon(Icons.download),
          label: Text('Save buffer CSV (${history.length} estimates)'),
        ),
      ],
    );
  }

  Widget _recordingSection({required bool canRecord}) {
    const options = {
      5: '5 seconds',
      10: '10 seconds',
      30: '30 seconds',
      -1: 'Custom'
    };
    final seconds = _recordingPeriod.inSeconds;
    return _AnalysisSection(
      title: 'CSV recording',
      children: [
        SizedBox(
          width: 280,
          child: _DurationSelect(
            label: 'Recording duration',
            value: options.containsKey(seconds) ? seconds : -1,
            options: options,
            semanticValue: options[seconds] ?? '$seconds seconds',
            onChanged: _recording
                ? null
                : (value) {
                    if (value == -1) {
                      _selectCustomRecordingPeriod();
                    } else if (value != null) {
                      setState(
                          () => _recordingPeriod = Duration(seconds: value));
                    }
                  },
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            if (!_recording)
              FilledButton.icon(
                onPressed: canRecord ? _startRecording : null,
                icon: const Icon(Icons.fiber_manual_record),
                label: const Text('Record CSV'),
              )
            else ...[
              FilledButton.icon(
                onPressed: _finishRecording,
                icon: const Icon(Icons.stop),
                label: const Text('Stop and save'),
              ),
              OutlinedButton(
                onPressed: () {
                  _recordingTimer?.cancel();
                  setState(() {
                    _recording = false;
                    _recordingStartedAt = null;
                    _recordedFrequency.clear();
                  });
                },
                child: const Text('Cancel'),
              ),
            ],
            if (!_recording && _recordedFrequency.isNotEmpty)
              OutlinedButton(
                onPressed: _saving ? null : _saveRecording,
                child: const Text('Save recording CSV'),
              ),
          ],
        ),
        if (_recording) ...[
          const SizedBox(height: 8),
          Text('Recording ${_recordedFrequency.length} estimates…'),
          Semantics(
            container: true,
            liveRegion: true,
            child:
                const Text('Stop and save or cancel before leaving this page.'),
          ),
        ],
        if (!_recording && _recordedFrequency.isNotEmpty) ...[
          const SizedBox(height: 8),
          Semantics(
            container: true,
            liveRegion: true,
            child: const Text(
                'Recording retained on this page; save it before leaving.'),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final arrival = _lastArrival;
    final stale = arrival != null && _now().difference(arrival) >= _staleAfter;
    final analysis = stale ? null : _analysis;
    final theme = Theme.of(context);
    final titleSize = theme.textTheme.titleLarge?.fontSize ?? 22;
    final scaledTitle = MediaQuery.textScalerOf(context).scale(titleSize);
    final toolbarHeight = (kToolbarHeight + (scaledTitle - titleSize) * 3)
        .clamp(kToolbarHeight, 84.0);

    return PopScope(
      canPop: !_recording,
      child: Scaffold(
        appBar: AppBar(
          title:
              const Text('IMU frequency analysis', softWrap: true, maxLines: 2),
          toolbarHeight: toolbarHeight,
        ),
        body: SafeArea(
          top: false,
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1000),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                children: [
                  Semantics(
                    container: true,
                    header: true,
                    child: Text('Single glove · live IMU',
                        style: theme.textTheme.headlineSmall),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                      'Explore periodic motion in the selected IMU signal. Peaks are estimates, not a clinical assessment.'),
                  const SizedBox(height: 12),
                  Semantics(
                    label: 'IMU signal',
                    container: true,
                    explicitChildNodes: true,
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
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
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  _liveSignal(
                      hasArrival: arrival != null,
                      stale: stale,
                      analysis: analysis),
                  const SizedBox(height: 12),
                  _frequencyResults(analysis),
                  const SizedBox(height: 12),
                  _bandSettings(),
                  const SizedBox(height: 12),
                  _historySection(),
                  const SizedBox(height: 12),
                  _recordingSection(
                    canRecord:
                        arrival != null && !stale && !_streamEnded && !_saving,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AnalysisSection extends StatelessWidget {
  const _AnalysisSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      color: scheme.surfaceContainerLow,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: DefaultTextStyle.merge(
          style: TextStyle(color: scheme.onSurface),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                container: true,
                header: true,
                child: Text(title, style: theme.textTheme.titleLarge),
              ),
              const SizedBox(height: 8),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

class _ControlGrid extends StatelessWidget {
  const _ControlGrid({
    required this.minWidth,
    required this.maxColumns,
    required this.children,
  });

  final double minWidth;
  final int maxColumns;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    const gap = 12.0;
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    return LayoutBuilder(builder: (context, constraints) {
      final available = constraints.maxWidth;
      final columns = ((available + gap) / (minWidth * scale + gap))
          .floor()
          .clamp(1, maxColumns);
      final width = (available - gap * (columns - 1)) / columns;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final child in children) SizedBox(width: width, child: child),
        ],
      );
    });
  }
}

class _DurationSelect extends StatelessWidget {
  const _DurationSelect({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.semanticValue,
  });

  final String label;
  final int value;
  final Map<int, String> options;
  final ValueChanged<int?>? onChanged;
  final String? semanticValue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final borderRadius = BorderRadius.circular(8);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ExcludeSemantics(
          child: Text(label, style: theme.textTheme.labelLarge),
        ),
        const SizedBox(height: 4),
        Semantics(
          label: label,
          value: semanticValue ?? options[value],
          enabled: onChanged != null,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: borderRadius,
              border: Border.all(color: theme.colorScheme.outline),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                value: value,
                isExpanded: true,
                itemHeight: null,
                borderRadius: borderRadius,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                items: [
                  for (final entry in options.entries)
                    DropdownMenuItem(
                        value: entry.key, child: Text(entry.value)),
                ],
                selectedItemBuilder: (context) => [
                  for (final name in options.values)
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: ExcludeSemantics(child: Text(name)),
                    ),
                ],
                onChanged: onChanged,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
