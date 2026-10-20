import 'package:flutter/material.dart';
import '../models/protocol.dart';

class ControlPanel extends StatefulWidget {
  final Future<void> Function(BleControlCommand cmd) onSendCommand;
  final List<String> commandHistory;

  const ControlPanel({
    super.key,
    required this.onSendCommand,
    required this.commandHistory,
  });

  @override
  State<ControlPanel> createState() => _ControlPanelState();
}

class _ControlPanelState extends State<ControlPanel> {
  double _requestedRate = 100;
  double _statusPeriodMs = 1000;
  bool _slowMode = false;

  void _send(BleControlCommand cmd) async {
    try {
      await widget.onSendCommand(cmd);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Sent: ${cmd.name}"), duration: const Duration(seconds: 1)),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Failed: $e"), backgroundColor: Colors.red),
      );
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
            Text("Notification Stream Rate: ${_requestedRate.toInt()} Hz"),
            Slider(
              min: 1,
              max: 200,
              value: _requestedRate,
              onChanged: (v) => setState(() => _requestedRate = v),
              onChangeEnd: (v) => _send(SetRateCommand(v.toInt())),
            ),
            Text("Status Update Period: ${_statusPeriodMs.toInt()} ms"),
            Slider(
              min: 250,
              max: 5000,
              value: _statusPeriodMs,
              onChanged: (v) => setState(() => _statusPeriodMs = v),
              onChangeEnd: (v) => _send(SetStatusPeriodCommand(v.toInt())),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("Slow/Debug Mode (0x04)"),
                Switch(
                  value: _slowMode,
                  onChanged: (val) {
                    setState(() => _slowMode = val);
                    _send(SetSlowModeCommand(val));
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
                  onPressed: () => _send(SensorRecoveryCommand()),
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade900),
                  icon: const Icon(Icons.power_settings_new),
                  label: const Text("Power Off (0x05)"),
                  onPressed: _confirmPowerOff,
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