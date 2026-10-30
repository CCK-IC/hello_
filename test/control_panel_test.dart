import 'dart:async';

import 'package:ble_imu_visualizer/models/protocol.dart';
import 'package:ble_imu_visualizer/widgets/control_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('selections survive updates and removal with a shared controller',
      (tester) async {
    final controller = ControlPanelController(requestedRate: 10);
    addTearDown(controller.dispose);
    final commands = <BleControlCommand>[];
    Widget panel() => MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ControlPanel(
                controller: controller,
                initialRateHz: 100,
                commandHistory: const [],
                onSendCommand: (command) async => commands.add(command),
              ),
            ),
          ),
        );

    await tester.pumpWidget(panel());
    expect(find.text('Notification Stream Rate: 10 Hz'), findsOneWidget);
    final sliders = tester.widgetList<Slider>(find.byType(Slider)).toList();
    sliders[0].onChanged!(42);
    sliders[0].onChangeEnd!(42);
    await tester.pump();
    sliders[1].onChanged!(2000);
    sliders[1].onChangeEnd!(2000);
    await tester.pump();
    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tester.pumpWidget(panel());
    expect(find.text('Notification Stream Rate: 42 Hz'), findsOneWidget);
    expect(find.text('Status Update Period: 2000 ms'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(commands.whereType<SetRateCommand>().single.rateHz, 42);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(panel());
    expect(find.text('Notification Stream Rate: 42 Hz'), findsOneWidget);
    expect(find.text('Status Update Period: 2000 ms'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  });

  testWidgets('controls disable while sending and failures restore saved values',
      (tester) async {
    final controller = ControlPanelController();
    addTearDown(controller.dispose);
    var pending = Completer<void>();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ControlPanel(
            controller: controller,
            commandHistory: const [],
            onSendCommand: (_) => pending.future,
          ),
        ),
      ),
    ));

    List<Slider> sliders() => tester.widgetList<Slider>(find.byType(Slider)).toList();
    sliders()[0].onChanged!(120);
    sliders()[0].onChangeEnd!(120);
    await tester.pump();
    expect(sliders().every((slider) => slider.onChanged == null), isTrue);
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
    pending.complete();
    await tester.pump();

    pending = Completer<void>();
    // Several drag updates must roll back to 120, not the previous update.
    sliders()[0].onChanged!(140);
    sliders()[0].onChanged!(160);
    sliders()[0].onChangeEnd!(160);
    pending.completeError(Exception('rate failed'));
    await tester.pump();
    expect(controller.requestedRate, 120);

    pending = Completer<void>();
    sliders()[1].onChanged!(3000);
    sliders()[1].onChangeEnd!(3000);
    pending.completeError(Exception('period failed'));
    await tester.pump();
    expect(controller.statusPeriodMs, 1000);

    pending = Completer<void>();
    tester.widget<Switch>(find.byType(Switch)).onChanged!(true);
    pending.completeError(Exception('mode failed'));
    await tester.pump();
    expect(controller.slowMode, isFalse);
  });

  testWidgets('starting another command discards an unfinished slider drag',
      (tester) async {
    final controller = ControlPanelController();
    addTearDown(controller.dispose);
    final pending = Completer<void>();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ControlPanel(
          controller: controller,
          commandHistory: const [],
          onSendCommand: (_) => pending.future,
        ),
      ),
    ));
    final rate = tester.widgetList<Slider>(find.byType(Slider)).first;
    rate.onChanged!(150);
    tester.widget<Switch>(find.byType(Switch)).onChanged!(true);
    // A stale gesture callback must not change the disabled slider either.
    rate.onChanged!(175);
    await tester.pump();
    expect(controller.requestedRate, 100);
    pending.complete();
    await tester.pump();
  });

  testWidgets('partial slow-mode write retains mode and marks rate unconfirmed',
      (tester) async {
    final controller = ControlPanelController(requestedRate: 42);
    addTearDown(controller.dispose);
    controller.markRateRestored(42);
    var failMode = true;
    var failRate = true;
    Widget panel() => MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ControlPanel(
                controller: controller,
                commandHistory: const [],
                onSendCommand: (command) async {
                  if (command is SetSlowModeCommand && failMode) {
                    throw SlowModeRateWriteException(Exception('rate write'));
                  }
                  if (command is SetRateCommand && failRate) {
                    throw Exception('rate write');
                  }
                },
              ),
            ),
          ),
        );

    await tester.pumpWidget(panel());
    tester.widget<Switch>(find.byType(Switch)).onChanged!(true);
    await tester.pump();
    expect(controller.slowMode, isTrue);
    expect(controller.requestedRate, 42);
    expect(controller.rateUnconfirmed, isTrue);
    expect(controller.lastRateSetByApp, 42);
    expect(find.textContaining('Selected rate not confirmed'), findsOneWidget);
    expect(find.textContaining('Slow mode changed, but restoring the rate failed'), findsOneWidget);

    // The state survives dashboard removal and reconnect preparation.
    await tester.pumpWidget(const SizedBox());
    controller.restorePendingSelections();
    await tester.pumpWidget(panel());
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(find.textContaining('Selected rate not confirmed'), findsOneWidget);

    var slider = tester.widgetList<Slider>(find.byType(Slider)).first;
    slider.onChanged!(50);
    slider.onChangeEnd!(50);
    await tester.pump();
    expect(controller.requestedRate, 42);
    expect(controller.rateUnconfirmed, isTrue);

    failRate = false;
    slider = tester.widgetList<Slider>(find.byType(Slider)).first;
    slider.onChanged!(50);
    slider.onChangeEnd!(50);
    await tester.pump();
    expect(controller.requestedRate, 50);
    expect(controller.rateUnconfirmed, isFalse);
    expect(controller.lastRateSetByApp, 50);
    expect(find.textContaining('Selected rate not confirmed'), findsNothing);

    // A successful mode change also confirms the follow-up rate write.
    failMode = true;
    tester.widget<Switch>(find.byType(Switch)).onChanged!(false);
    await tester.pump();
    expect(controller.slowMode, isFalse);
    expect(controller.rateUnconfirmed, isTrue);
    failMode = false;
    tester.widget<Switch>(find.byType(Switch)).onChanged!(true);
    await tester.pump();
    expect(controller.slowMode, isTrue);
    expect(controller.rateUnconfirmed, isFalse);
  });

  testWidgets('switching controllers detaches the old listener', (tester) async {
    final first = ControlPanelController();
    final second = ControlPanelController(requestedRate: 25);
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    Widget panel(ControlPanelController controller) => MaterialApp(
          home: Scaffold(
            body: ControlPanel(
              controller: controller,
              commandHistory: const [],
              onSendCommand: (_) async {},
            ),
          ),
        );

    await tester.pumpWidget(panel(first));
    await tester.pumpWidget(panel(second));
    first.requestedRate = 35;
    second.requestedRate = 50;
    await tester.pump();
    expect(find.text('Notification Stream Rate: 50 Hz'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    second.requestedRate = 60;
    expect(tester.takeException(), isNull);
  });
}
