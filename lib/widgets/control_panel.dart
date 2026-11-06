import 'package:flutter/material.dart';
import '../models/protocol.dart';

const double defaultRequestedRateHz = 45;

/// The slow-mode write succeeded, but restoring the selected rate failed.
/// Throw only after the first write completes successfully.
class SlowModeRateWriteException implements Exception {
  final Object cause;
  const SlowModeRateWriteException(this.cause);

  @override
  String toString() =>
      'Slow mode changed, but restoring the rate failed: $cause';
}

/// Own this above the connected dashboard to retain selections across reconnects.
/// Values represent user selections, not acknowledged peripheral settings.
class ControlPanelController extends ChangeNotifier {
  ControlPanelController({
    double requestedRate = defaultRequestedRateHz,
    double statusPeriodMs = 1000,
    bool slowMode = false,
    int? lastRateSetByApp,
  })  : assert(requestedRate >= 1 && requestedRate <= 200),
        assert(statusPeriodMs >= 250 && statusPeriodMs <= 5000),
        _lastRateSetByApp = lastRateSetByApp,
        _requestedRate = requestedRate,
        _statusPeriodMs = statusPeriodMs,
        _slowMode = slowMode,
        _savedRate = requestedRate,
        _savedStatusPeriodMs = statusPeriodMs,
        _savedSlowMode = slowMode;

  double _requestedRate;
  double _statusPeriodMs;
  bool _slowMode;
  double _savedRate;
  double _savedStatusPeriodMs;
  bool _savedSlowMode;
  bool _disposed = false;
  bool _rateUnconfirmed = false;
  int? _lastRateSetByApp;
  int _connectionGeneration = 0;

  /// Last rate successfully sent on the current connection.
  int? get lastRateSetByApp => _lastRateSetByApp;

  /// Start tracking a new connection without changing the user selections.
  void clearLastRateSet() {
    _connectionGeneration++;
    if (_lastRateSetByApp == null) return;
    _lastRateSetByApp = null;
    notifyListeners();
  }

  /// The selected rate has not been confirmed since a partial mode change.
  bool get rateUnconfirmed => _rateUnconfirmed;

  void _markRateUnconfirmed() {
    if (_rateUnconfirmed) return;
    _rateUnconfirmed = true;
    notifyListeners();
  }

  /// Record the actual rate successfully sent, including during setup.
  /// Pass the sent rate when it may differ from the current selection.
  void markRateRestored([int? rateHz]) {
    final sentRate = rateHz ?? _requestedRate.toInt();
    final changed = _lastRateSetByApp != sentRate ||
        (_rateUnconfirmed && sentRate == _requestedRate.toInt());
    _lastRateSetByApp = sentRate;
    if (sentRate == _requestedRate.toInt()) _rateUnconfirmed = false;
    if (changed) notifyListeners();
  }

  double get requestedRate => _requestedRate;
  set requestedRate(double value) {
    assert(value >= 1 && value <= 200);
    _savedRate = value;
    _previewRate(value);
  }

  void _previewRate(double value) {
    if (_requestedRate == value) return;
    _requestedRate = value;
    notifyListeners();
  }

  double get statusPeriodMs => _statusPeriodMs;
  set statusPeriodMs(double value) {
    assert(value >= 250 && value <= 5000);
    _savedStatusPeriodMs = value;
    _previewStatusPeriod(value);
  }

  void _previewStatusPeriod(double value) {
    if (_statusPeriodMs == value) return;
    _statusPeriodMs = value;
    notifyListeners();
  }

  bool get slowMode => _slowMode;
  set slowMode(bool value) {
    _savedSlowMode = value;
    _previewSlowMode(value);
  }

  void _previewSlowMode(bool value) {
    if (_slowMode == value) return;
    _slowMode = value;
    notifyListeners();
  }

  /// Discard unfinished gestures before restoring settings on a new link.
  void restorePendingSelections() {
    _previewRate(_savedRate);
    _previewStatusPeriod(_savedStatusPeriodMs);
    _previewSlowMode(_savedSlowMode);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class ControlPanel extends StatefulWidget {
  final Future<void> Function(BleControlCommand cmd) onSendCommand;
  final List<String> commandHistory;
  final int? initialRateHz;

  /// If supplied, the owner retains and disposes this controller.
  final ControlPanelController? controller;

  const ControlPanel({
    super.key,
    required this.onSendCommand,
    required this.commandHistory,
    this.initialRateHz,
    this.controller,
  });

  @override
  State<ControlPanel> createState() => _ControlPanelState();
}

class _ControlPanelState extends State<ControlPanel> {
  late ControlPanelController _controller;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _attachController();
  }

  void _attachController() {
    _controller = widget.controller ??
        ControlPanelController(
          requestedRate:
              widget.initialRateHz?.toDouble() ?? defaultRequestedRateHz,
          lastRateSetByApp: widget.initialRateHz,
        );
    _controller.addListener(_onValuesChanged);
  }

  void _onValuesChanged() => setState(() {});

  @override
  void didUpdateWidget(covariant ControlPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _controller.removeListener(_onValuesChanged);
      if (oldWidget.controller == null) _controller.dispose();
      _attachController();
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onValuesChanged);
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  void _send(BleControlCommand cmd,
      {void Function(Object? error)? onComplete}) async {
    if (_sending) return;
    // Another slider may be in the middle of a drag when a command starts.
    // Discard that unsent preview before disabling the controls.
    if (cmd is! SetRateCommand) {
      _controller._previewRate(_controller._savedRate);
    }
    if (cmd is! SetStatusPeriodCommand) {
      _controller._previewStatusPeriod(_controller._savedStatusPeriodMs);
    }
    final controller = _controller;
    final generation = controller._connectionGeneration;
    final restoredRate = controller.requestedRate.toInt();
    setState(() => _sending = true);
    try {
      await widget.onSendCommand(cmd);
      if (!controller._disposed &&
          generation == controller._connectionGeneration) {
        onComplete?.call(null);
        if (cmd is SetRateCommand) {
          controller.markRateRestored(cmd.rateHz);
        } else if (cmd is SetSlowModeCommand) {
          controller.markRateRestored(restoredRate);
        }
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text("Sent: ${cmd.name}"),
            duration: const Duration(seconds: 1)),
      );
    } catch (e) {
      if (!controller._disposed &&
          generation == controller._connectionGeneration) {
        onComplete?.call(e);
      }
      if (!mounted) return;
      final colors = Theme.of(context).colorScheme;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed: $e',
              style: TextStyle(color: colors.onErrorContainer)),
          backgroundColor: colors.errorContainer,
        ),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _commitRate(double value) {
    final controller = _controller;
    final rateHz = value.toInt();
    _send(SetRateCommand(rateHz), onComplete: (error) {
      if (controller.requestedRate != value) return;
      if (error == null) {
        controller.requestedRate = rateHz.toDouble();
      } else {
        controller._previewRate(controller._savedRate);
      }
    });
  }

  void _commitStatusPeriod(double value) {
    final controller = _controller;
    final periodMs = value.toInt();
    _send(SetStatusPeriodCommand(periodMs), onComplete: (error) {
      if (controller.statusPeriodMs != value) return;
      if (error == null) {
        controller.statusPeriodMs = periodMs.toDouble();
      } else {
        controller._previewStatusPeriod(controller._savedStatusPeriodMs);
      }
    });
  }

  void _setSlowMode(bool value) {
    if (_sending) return;
    final controller = _controller;
    controller._previewSlowMode(value);
    _send(SetSlowModeCommand(value), onComplete: (error) {
      if (controller.slowMode != value) return;
      if (error == null || error is SlowModeRateWriteException) {
        controller.slowMode = value;
        if (error is SlowModeRateWriteException) {
          controller._markRateUnconfirmed();
        }
      } else {
        controller._previewSlowMode(controller._savedSlowMode);
      }
    });
  }

  void _confirmPowerOff() {
    showDialog(
      context: context,
      builder: (ctx) {
        final colors = Theme.of(ctx).colorScheme;
        return AlertDialog(
          scrollable: true,
          title: const Text('Confirm Power Off'),
          content: const Text(
            'This command (0x05 A5 5A) will shut down the peripheral. Proceed?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('CANCEL'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: colors.error,
                foregroundColor: colors.onError,
              ),
              onPressed: () {
                Navigator.pop(ctx);
                _send(PowerOffCommand());
              },
              child: const Text('POWER OFF'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSlider({
    required String label,
    required String unit,
    required String spokenUnit,
    required double min,
    required double max,
    required double value,
    required ValueChanged<double> onPreview,
    required ValueChanged<double> onCommit,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ExcludeSemantics(child: Text('$label: ${value.toInt()} $unit')),
        Slider(
          label: label,
          min: min,
          max: max,
          value: value,
          semanticFormatterCallback: (value) => '${value.toInt()} $spokenUnit',
          onChanged: _sending
              ? null
              : (value) {
                  if (!_sending) onPreview(value);
                },
          onChangeEnd: _sending ? null : onCommit,
        ),
      ],
    );
  }

  Widget _buildRateControl(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final lastRate = _controller.lastRateSetByApp;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSlider(
          label: 'Notification Stream Rate',
          unit: 'Hz',
          spokenUnit: 'hertz',
          min: 1,
          max: 200,
          value: _controller.requestedRate,
          onPreview: _controller._previewRate,
          onCommit: _commitRate,
        ),
        Text(
          lastRate == null
              ? 'Stream rate has not been set by this app'
              : 'Last rate set by app: $lastRate Hz',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: colors.onSurfaceVariant),
        ),
        if (_controller.rateUnconfirmed)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Semantics(
              liveRegion: true,
              child: Text(
                'Selected rate not confirmed on device; send the rate again.',
                style:
                    theme.textTheme.bodyMedium?.copyWith(color: colors.error),
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final actionStyle = OutlinedButton.styleFrom(
      minimumSize: const Size(0, 48),
      visualDensity: VisualDensity.standard,
    );

    Widget heading(String text, TextStyle? style) => Semantics(
          header: true,
          child: Text(text, style: style),
        );

    return Card(
      color: colors.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            heading('Control Commands', theme.textTheme.titleLarge),
            const SizedBox(height: 12),
            heading('Stream settings', theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            LayoutBuilder(
              builder: (context, constraints) {
                const gap = 24.0;
                final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
                final width = constraints.maxWidth;
                final sliderWidth =
                    width >= 600 * scale ? (width - gap) / 2 : width;
                return Wrap(
                  spacing: gap,
                  runSpacing: 8,
                  children: [
                    SizedBox(
                      width: sliderWidth,
                      child: _buildRateControl(context),
                    ),
                    SizedBox(
                      width: sliderWidth,
                      child: _buildSlider(
                        label: 'Status Update Period',
                        unit: 'ms',
                        spokenUnit: 'milliseconds',
                        min: 250,
                        max: 5000,
                        value: _controller.statusPeriodMs,
                        onPreview: _controller._previewStatusPeriod,
                        onCommit: _commitStatusPeriod,
                      ),
                    ),
                  ],
                );
              },
            ),
            SwitchListTile(
              title: const Text('Slow/Debug Mode (0x04)'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _controller.slowMode,
              onChanged: _sending ? null : _setSlowMode,
            ),
            const Divider(height: 24),
            heading('Device actions', theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  style: actionStyle,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reinit IMU (0x06)'),
                  onPressed:
                      _sending ? null : () => _send(SensorRecoveryCommand()),
                ),
                OutlinedButton.icon(
                  style: actionStyle.merge(
                      OutlinedButton.styleFrom(foregroundColor: colors.error)),
                  icon: const Icon(Icons.power_settings_new),
                  label: const Text('Power Off (0x05)'),
                  onPressed: _sending ? null : _confirmPowerOff,
                ),
              ],
            ),
            const Divider(height: 24),
            heading('Command History', theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 128),
                child: widget.commandHistory.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          'No commands sent yet.',
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                      )
                    : ListView.builder(
                        primary: false,
                        shrinkWrap: true,
                        padding: const EdgeInsets.all(12),
                        itemCount: widget.commandHistory.length,
                        itemBuilder: (context, index) => Text(
                          widget.commandHistory[
                              widget.commandHistory.length - 1 - index],
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colors.onSurface,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
