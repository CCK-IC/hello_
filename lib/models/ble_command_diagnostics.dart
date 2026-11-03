import 'package:flutter/foundation.dart';

/// Logs control-operation outcomes without including device IDs or payloads.
/// The original result and exception (including its stack) are preserved.
Future<T> runLoggedBleCommand<T>(
  String name,
  Future<T> Function() operation, {
  required bool enabled,
  DateTime Function()? clock,
  void Function(String)? log,
}) async {
  void emit(String outcome) {
    if (!enabled) return;
    final timestamp = (clock?.call() ?? DateTime.now()).toUtc().toIso8601String();
    (log ?? debugPrint)('BLE command: $timestamp $outcome $name');
  }

  emit('start');
  try {
    final result = await operation();
    emit('success');
    return result;
  } catch (error) {
    emit('failure type=${error.runtimeType}');
    rethrow;
  }
}
