import 'package:flutter/material.dart';
import '../models/protocol.dart';

/// The slow-mode write succeeded, but restoring the selected rate failed.
/// Throw only after the first write completes successfully.
class SlowModeRateWriteException implements Exception {
  final Object cause;
  const SlowModeRateWriteException(this.cause);

  @override
  String toString() => 'Slow mode changed, but restoring the rate failed: $cause';
}

/// Own this above the connected dashboard to retain selections across reconnects.
/// Values represent user selections, not acknowledged peripheral settings.
class ControlPanelController extends ChangeNotifier {
  ControlPanelController({
    double requestedRate = 100,
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
          requestedRate: (widget.initialRateHz ?? 25).toDouble(),
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

  void _send(BleControlCommand cmd, {void Function(Object? error)? onComplete}) async {
    if (_sending) return;
    // Another slider may be in the middle of a drag when a command starts.
    // Discard that unsent preview before disabling the controls.
    if (cmd is! SetRateCommand) _controller._previewRate(_controller._savedRate);
    if (cmd is! SetStatusPeriodCommand) {
      _controller._previewStatusPeriod(_controller._savedStatusPeriodMs);
    }
    final controller = _controller;
    final generation = controller._connectionGeneration;
    final restoredRate = controller.requestedRate.toInt();
    setState(() => _sending = true);
    try {
      await widget.onSendCommand(cmd);
      if (!controller._disposed && generation == controller._connectionGeneration) {
        onComplete?.call(null);
        if (cmd is SetRateCommand) {
          controller.markRateRestored(cmd.rateHz);
        } else if (cmd is SetSlowModeCommand) {
          controller.markRateRestored(restoredRate);
        }
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Sent: ${cmd.name}"), duration: const Duration(seconds: 1)),
      );
    } catch (e) {
      if (!controller._disposed && generation == controller._connectionGeneration) {
        onComplete?.call(e);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Failed: $e"), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _confirmPowerOff() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Confirm Power Off"),
        content: const Text("This command (0x05 A5 5A) will shut down the peripheral. Proceed?"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CANCEL")),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              Navigator.pop(ctx);
              _send(PowerOffCommand());
            },
            child: const Text("POWER OFF"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color.fromARGB(255, 138, 158, 216),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text("Control Commands", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Text("Notification Stream Rate: ${_controller.requestedRate.toInt()} Hz"),
            Text(_controller.lastRateSetByApp == null
                ? "Stream rate has not been set by this app"
                : "Last rate set by app: ${_controller.lastRateSetByApp} Hz"),
            if (_controller.rateUnconfirmed)
              const Text("Selected rate not confirmed on device; send the rate again."),
            Slider(
              min: 1,
              max: 200,
              value: _controller.requestedRate,
              onChanged: _sending ? null : (v) {
                if (!_sending) _controller._previewRate(v);
              },
              onChangeEnd: _sending ? null : (v) {
                final controller = _controller;
                _send(SetRateCommand(v.toInt()), onComplete: (error) {
                  if (controller._disposed || controller.requestedRate != v) return;
                  if (error == null) {
                    controller.requestedRate = v.toInt().toDouble();
                  } else {
                    controller._previewRate(controller._savedRate);
                  }
                });
              },
            ),
            Text("Status Update Period: ${_controller.statusPeriodMs.toInt()} ms"),
            Slider(
              min: 250,
              max: 5000,
              value: _controller.statusPeriodMs,
              onChanged: _sending ? null : (v) {
                if (!_sending) _controller._previewStatusPeriod(v);
              },
              onChangeEnd: _sending ? null : (v) {
                final controller = _controller;
                _send(SetStatusPeriodCommand(v.toInt()), onComplete: (error) {
                  if (controller._disposed || controller.statusPeriodMs != v) return;
                  if (error == null) {
                    controller.statusPeriodMs = v.toInt().toDouble();
                  } else {
                    controller._previewStatusPeriod(controller._savedStatusPeriodMs);
                  }
                });
              },
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("Slow/Debug Mode (0x04)"),
                Switch(
                  value: _controller.slowMode,
                  onChanged: _sending ? null : (val) {
                    if (_sending) return;
                    final controller = _controller;
                    controller._previewSlowMode(val);
                    _send(SetSlowModeCommand(val), onComplete: (error) {
                      if (controller._disposed || controller.slowMode != val) return;
                      if (error == null || error is SlowModeRateWriteException) {
                        controller.slowMode = val;
                        if (error is SlowModeRateWriteException) {
                          controller._markRateUnconfirmed();
                        }
                      } else {
                        controller._previewSlowMode(controller._savedSlowMode);
                      }
                    });
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.refresh),
                  label: const Text("Reinit IMU (0x06)"),
                  onPressed: _sending ? null : () => _send(SensorRecoveryCommand()),
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade900),
                  icon: const Icon(Icons.power_settings_new),
                  label: const Text("Power Off (0x05)"),
                  onPressed: _sending ? null : _confirmPowerOff,
                ),
              ],
            ),
            const Divider(height: 20),
            const Text("Command History", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            Container(
              height: 60,
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(4),
              ),
              child: ListView(
                children: widget.commandHistory.reversed
                    .map((item) => Text(item, style: const TextStyle(fontSize: 11, fontFamily: 'monospace')))
                    .toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
