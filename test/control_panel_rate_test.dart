import 'package:ble_imu_visualizer/models/protocol.dart';
import 'package:ble_imu_visualizer/widgets/control_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> showPanel(WidgetTester tester, {
    int? initialRate,
    required Future<void> Function(BleControlCommand) send,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ControlPanel(
            initialRateHz: initialRate,
            commandHistory: const [],
            onSendCommand: send,
          ),
        ),
      ),
    ));
  }

  testWidgets('does not claim a rate when none was sent by the app',
      (tester) async {
    await showPanel(tester, send: (_) async {});
    expect(find.text('Stream rate has not been set by this app'), findsOneWidget);
    expect(find.text('Last rate set by app: 25 Hz'), findsNothing);
  });

  testWidgets('shows the rate successfully sent during connection setup',
      (tester) async {
    await showPanel(tester, initialRate: 25, send: (_) async {});
    expect(find.text('Last rate set by app: 25 Hz'), findsOneWidget);
  });

  testWidgets('updates the last sent rate only after a successful write',
      (tester) async {
    final commands = <BleControlCommand>[];
    await showPanel(tester, send: (command) async => commands.add(command));

    await tester.drag(find.byType(Slider).first, const Offset(60, 0));
    await tester.pump();
    await tester.pump();

    final command = commands.single as SetRateCommand;
    expect(find.text('Last rate set by app: ${command.rateHz} Hz'), findsOneWidget);
  });

  testWidgets('a failed rate write does not change the last sent rate',
      (tester) async {
    await showPanel(tester, initialRate: 25, send: (_) async {
      throw StateError('write failed');
    });

    await tester.drag(find.byType(Slider).first, const Offset(60, 0));
    await tester.pump();
    await tester.pump();

    expect(find.text('Last rate set by app: 25 Hz'), findsOneWidget);
    expect(find.textContaining('write failed'), findsOneWidget);
  });
}
