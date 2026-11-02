import 'dart:async';

import 'package:flutter/material.dart';

import '../models/imu_frequency_analysis.dart';
import '../models/raw_imu_history.dart';

/// Live, session-scoped analysis of one connected glove.
/// A null event clears the current session.
class ImuAnalysisPage extends StatefulWidget {
  const ImuAnalysisPage({super.key, required this.samples, this.clock});

  final Stream<RawImuHistoryPoint?> samples;

  /// Optional clock for deterministic tests.
  final DateTime Function()? clock;

  @override
  State<ImuAnalysisPage> createState() => _ImuAnalysisPageState();
}

class _ImuAnalysisPageState extends State<ImuAnalysisPage> {
  static const _staleAfter = Duration(seconds: 3);
  static const _retention = Duration(seconds: 12);
  static const _maxSamples = 4096;

  final _points = <RawImuHistoryPoint>[];
  RawSensorType _sensor = RawSensorType.accelerometer;
  final _lowerMin = TextEditingController(text: '0.5');
  final _lowerMax = TextEditingController(text: '5');
  final _upperMin = TextEditingController(text: '5');
  final _upperMax = TextEditingController(text: '12');
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
    _bands = const [
      FrequencyBand('Percussion band', 0.5, 5),
      FrequencyBand('Vibration band', 5, 12),
    ];
    _listen();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _update());
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
    _points.clear();
    _lastArrival = null;
    _analysis = null;
    _streamEnded = false;
  }

  void _update() {
    if (!mounted) return;
    final arrival = _lastArrival;
    if (arrival == null || _now().difference(arrival) >= _staleAfter) {
      if (_analysis != null || (arrival != null && _points.isNotEmpty)) {
        setState(() {
          _analysis = null;
          _points.clear();
        });
      }
      return;
    }
    setState(() => _analysis = ImuFrequencyAnalyzer.analyze(
          _points,
          bands: _bands,
          sensor: _sensor,
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
    });
    _update();
  }

  @override
  void dispose() {
    _timer?.cancel();
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

  @override
  Widget build(BuildContext context) {
    final arrival = _lastArrival;
    final stale = arrival != null && _now().difference(arrival) >= _staleAfter;
    final analysis = stale ? null : _analysis;

    return Scaffold(
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
                    Text('Candidate spectral peaks',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    const Text(
                        'A peak may reflect noise or a harmonic, rather than the movement frequency. Weak real signals may be suppressed. Verify against a reference measurement.'),
                    const SizedBox(height: 8),
                    if (analysis == null || analysis.error != null)
                      const Text(
                          'Estimates appear when enough reliable samples arrive.')
                    else
                      for (final result in analysis.bands)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                  '${result.band.label} · ${result.band.minHz}–${result.band.maxHz} Hz',
                                  style:
                                      Theme.of(context).textTheme.titleSmall),
                              Text(result.peakHz == null
                                  ? result.unavailableReason ?? 'Unavailable'
                                  : '${result.peakHz!.toStringAsFixed(2)} Hz candidate'),
                            ],
                          ),
                        ),
                  ]),
            ),
          ),
        ],
      ),
    );
  }
}
