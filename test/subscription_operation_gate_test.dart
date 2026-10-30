import 'package:ble_imu_visualizer/models/subscription_operation_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a stream cannot be changed twice while its CCC write is pending', () {
    final gate = SubscriptionOperationGate();
    final raw = gate.begin('raw')!;

    expect(gate.begin('raw'), isNull);
    expect(gate.begin('status'), isNotNull);
    expect(gate.finish('raw', raw), isTrue);
    expect(gate.canStart('raw'), isTrue);
  });

  test('a timed-out write remains blocked until a connection reset', () {
    final gate = SubscriptionOperationGate();
    final token = gate.begin('raw')!;

    expect(gate.finish('raw', token, timedOut: true), isTrue);
    expect(gate.canStart('raw'), isFalse);
    gate.reset();
    expect(gate.canStart('raw'), isTrue);
  });

  test('old connection completion cannot release a new operation', () {
    final gate = SubscriptionOperationGate();
    final old = gate.begin('raw')!;
    gate.reset();
    final current = gate.begin('raw')!;

    expect(gate.finish('raw', old, timedOut: true), isFalse);
    expect(gate.canStart('raw'), isFalse);
    expect(gate.finish('raw', current), isTrue);
    expect(gate.canStart('raw'), isTrue);
  });
}
