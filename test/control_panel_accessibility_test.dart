import 'package:ble_imu_visualizer/models/protocol.dart';
import 'package:ble_imu_visualizer/widgets/control_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> showPanel(
    WidgetTester tester,
    List<BleControlCommand> commands, {
    double textScale = 1,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorSchemeSeed: const Color(0xFF0D6F73)),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
          ),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: ControlPanel(
              commandHistory: const [],
              onSendCommand: (command) async => commands.add(command),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('slider semantics announce units and send adjustments', (
    tester,
  ) async {
    final commands = <BleControlCommand>[];
    await showPanel(tester, commands);

    Finder slider(String label) => find.byWidgetPredicate(
          (widget) => widget is Slider && widget.label == label,
        );
    final imuSlider = slider('IMU Sample Rate');
    final statusSlider = slider('Status Update Period');
    final adcSlider = slider('ADC Sample Rate');
    final rate = tester.getSemantics(imuSlider);
    final period = tester.getSemantics(statusSlider);
    expect(rate.label, 'IMU Sample Rate');
    expect(rate.value, '45 hertz');
    expect(rate.getSemanticsData().flagsCollection.isSlider, isTrue);
    expect(rate.getSemanticsData().hasAction(SemanticsAction.increase), isTrue);
    expect(period.label, 'Status Update Period');
    expect(period.value, '1000 milliseconds');
    expect(
        period.getSemanticsData().hasAction(SemanticsAction.decrease), isTrue);

    rate.owner!.performAction(rate.id, SemanticsAction.increase);
    await tester.pump();
    final sentRate = (commands.single as SetRateCommand).rateHz;
    expect(sentRate, greaterThan(45));
    expect(tester.getSemantics(imuSlider).value, '$sentRate hertz');

    final updatedPeriod = tester.getSemantics(statusSlider);
    updatedPeriod.owner!
        .performAction(updatedPeriod.id, SemanticsAction.decrease);
    await tester.pump();
    final sentPeriod = (commands.last as SetStatusPeriodCommand).periodMs;
    expect(sentPeriod, lessThan(1000));
    expect(tester.getSemantics(statusSlider).value, '$sentPeriod milliseconds');

    final adc = tester.getSemantics(adcSlider);
    expect(adc.value, '100 hertz');
    adc.owner!.performAction(adc.id, SemanticsAction.decrease);
    await tester.pump();
    final sentAdcRate = (commands.last as SetAdcRateCommand).rateHz;
    expect(sentAdcRate, lessThan(100));
    expect(tester.getSemantics(adcSlider).value, '$sentAdcRate hertz');

    final slowMode = tester.getSemantics(find.byType(Switch));
    expect(slowMode.label, 'Slow/Debug Mode (0x04)');
    expect(slowMode.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
  });

  testWidgets('controls fit desktop and a narrow phone at double text size', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 640);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final commands = <BleControlCommand>[];
    final rate = find.text('IMU Sample Rate: 45 Hz');
    final period = find.text('Status Update Period: 1000 ms');

    await showPanel(tester, commands);
    expect(tester.getTopLeft(rate).dy, tester.getTopLeft(period).dy);
    expect(tester.getTopLeft(rate).dx, lessThan(tester.getTopLeft(period).dx));

    tester.view.physicalSize = const Size(320, 640);
    await showPanel(tester, commands, textScale: 2);
    expect(tester.getTopLeft(rate).dx, tester.getTopLeft(period).dx);
    expect(
        tester.getBottomLeft(rate).dy, lessThan(tester.getTopLeft(period).dy));
    expect(tester.takeException(), isNull);

    final powerOff = find.text('Power Off (0x05)');
    await tester.ensureVisible(powerOff);
    await tester.tap(powerOff);
    await tester.pumpAndSettle();
    expect(find.text('Confirm Power Off'), findsOneWidget);
    expect(commands, isEmpty);
    await tester.tap(find.text('POWER OFF'));
    await tester.pumpAndSettle();
    expect(commands.single, isA<PowerOffCommand>());
  });
}
