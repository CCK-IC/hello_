import 'dart:async';

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
  testWidgets('controller tracks setup, reconnect, and stale writes', (tester) async {
    final controller = ControlPanelController(requestedRate: 42);
    addTearDown(controller.dispose);
    controller.markRateRestored(42);
    final pending = Completer<void>();
    Widget panel() => MaterialApp(home: Scaffold(body: SingleChildScrollView(
      child: ControlPanel(controller: controller, commandHistory: const [],
          onSendCommand: (_) => pending.future),
    )));
    await tester.pumpWidget(panel());
    expect(find.text('Last rate set by app: 42 Hz'), findsOneWidget);
    final slider = tester.widgetList<Slider>(find.byType(Slider)).first;
    slider.onChanged!(50);
    slider.onChangeEnd!(50);
    await tester.pumpWidget(const SizedBox());
    controller.clearLastRateSet();
    controller.restorePendingSelections();
    pending.complete();
    await tester.pump();
    expect(controller.lastRateSetByApp, isNull);
    expect(controller.requestedRate, 42);
    controller.markRateRestored(42);
    await tester.pumpWidget(panel());
    expect(find.text('Last rate set by app: 42 Hz'), findsOneWidget);
  });

  testWidgets('successful write survives panel removal', (tester) async {
    final controller = ControlPanelController(requestedRate: 42);
    addTearDown(controller.dispose);
    final pending = Completer<void>();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ControlPanel(
      controller: controller, commandHistory: const [],
      onSendCommand: (_) => pending.future,
    ))));
    final slider = tester.widgetList<Slider>(find.byType(Slider)).first;
    slider.onChanged!(50);
    slider.onChangeEnd!(50);
    await tester.pumpWidget(const SizedBox());
    pending.complete();
    await tester.pump();
    expect(controller.lastRateSetByApp, 50);
    expect(controller.requestedRate, 50);
  });

}
