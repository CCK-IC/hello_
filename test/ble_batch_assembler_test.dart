import 'dart:typed_data';

import 'package:ble_imu_visualizer/models/ble_batch_assembler.dart';
import 'package:ble_imu_visualizer/models/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

import 'batch_test_fixtures.dart';

void main() {
  final now = DateTime.utc(2026);
  test(
      'whole legacy/v3 input passes through unchanged and clears pending parts',
      () {
    final assembler = BleBatchAssembler(expectedKind: 1);
    for (final frame in [Uint8List(20)..[0] = 2, sensorFrame(), Uint8List(0)]) {
      final result = assembler.add(frame, now: now);
      expect(identical(result.frame, frame), isTrue);
      expect(result.invalid, isFalse);
    }
    final parts = fragments(sensorFrame());
    assembler.add(parts.first, now: now);
    assembler.add(sensorFrame(), now: now);
    expect(assembler.add(parts[1], now: now).invalid, isTrue);
  });

  for (final kind in [1, 2, 3, 4]) {
    test(
        'kind $kind emits exactly one complete copied frame after ordered fragments',
        () {
      final frame =
          kind == 4 ? statusFrame() : sensorFrame(kind: kind, rows: 8);
      final parts = fragments(frame);
      final assembler = BleBatchAssembler(expectedKind: kind);
      for (var i = 0; i < parts.length; i++) {
        final result = assembler.add(parts[i],
            now: now.add(Duration(milliseconds: i * 10)));
        expect(result.invalid, isFalse);
        if (i < parts.length - 1) {
          expect(result.frame, isNull);
        } else {
          expect(result.frame, orderedEquals(frame));
          if (kind == 1) {
            expect(RawImuSample.decodeAll(result.frame!)!.length, 8);
          }
        }
        parts[i]
            .fillRange(8, parts[i].length, 0); // Never retain caller's buffer.
      }
    });
  }

  test('rejects missing, duplicate and out-of-order fragments and resets', () {
    final parts = fragments(sensorFrame());
    for (final order in [
      [1],
      [0, 2],
      [0, 1, 1]
    ]) {
      final assembler = BleBatchAssembler();
      BatchAssemblyResult? result;
      for (final index in order) {
        result = assembler.add(parts[index], now: now);
      }
      expect(result!.invalid, isTrue);
      expect(result.frame, isNull);
      expect(assembler.add(parts[2], now: now).invalid, isTrue);
    }
  });

  test('a new frame0 replaces pending assembly including wrapped frame IDs',
      () {
    final assembler = BleBatchAssembler(expectedKind: 1);
    final oldParts = fragments(sensorFrame(), id: 65535);
    final frame = sensorFrame(rows: 2, sequence: 100);
    final newParts = fragments(frame, id: 0);
    assembler.add(oldParts[0], now: now);
    assembler.add(oldParts[1], now: now);
    BatchAssemblyResult? result;
    for (final part in newParts) {
      result = assembler.add(part, now: now);
    }
    expect(result!.frame, orderedEquals(frame));
    expect(result.invalid, isFalse);
  });

  test('one-second absolute expiry, explicit reset and recovery', () {
    final parts = fragments(sensorFrame(rows: 1));
    final assembler = BleBatchAssembler();
    assembler.add(parts[0], now: now);
    expect(
        assembler
            .add(parts[1], now: now.add(const Duration(milliseconds: 999)))
            .invalid,
        isFalse);
    expect(
        assembler
            .add(parts[2], now: now.add(const Duration(seconds: 1)))
            .invalid,
        isTrue);
    assembler.add(parts[0], now: now);
    assembler.reset();
    expect(assembler.add(parts[1], now: now).invalid, isTrue);
    BatchAssemblyResult? result;
    for (final part in parts) {
      result = assembler.add(part, now: now.add(const Duration(seconds: 2)));
    }
    expect(result!.frame, orderedEquals(sensorFrame(rows: 1)));
  });

  test('rejects changed kind, id, count, total and fragment payload width', () {
    final parts = fragments(sensorFrame());
    for (final entry
        in {1: 2, 2: 0, 3: 0, 5: parts.length + 1, 6: 76}.entries) {
      final assembler = BleBatchAssembler();
      assembler.add(parts[0], now: now);
      final bad = Uint8List.fromList(parts[1])..[entry.key] = entry.value;
      expect(assembler.add(bad, now: now).invalid, isTrue);
    }
    for (final bad in [
      Uint8List.sublistView(parts[1], 0, parts[1].length - 1),
      Uint8List.fromList([...parts[1], 0]),
    ]) {
      final assembler = BleBatchAssembler();
      assembler.add(parts[0], now: now);
      expect(assembler.add(bad, now: now).invalid, isTrue);
    }
  });

  test(
      'rejects malformed headers, impossible counts/lengths and wrong characteristic',
      () {
    final first = fragments(sensorFrame()).first;
    for (var length = 1; length <= 8; length++) {
      expect(
          BleBatchAssembler()
              .add(Uint8List.sublistView(first, 0, length), now: now)
              .invalid,
          isTrue);
    }
    for (final entry in {1: 5, 4: 255, 5: 0, 6: 0, 7: 3}.entries) {
      final bad = Uint8List.fromList(first)..[entry.key] = entry.value;
      expect(BleBatchAssembler().add(bad, now: now).invalid, isTrue);
    }
    expect(BleBatchAssembler(expectedKind: 3).add(first, now: now).invalid,
        isTrue);
    for (final count in [1, 2, 255]) {
      final bad = Uint8List.fromList(first)..[5] = count;
      expect(BleBatchAssembler().add(bad, now: now).invalid, isTrue);
    }
    final zeroTotal = Uint8List.fromList(first)
      ..[6] = 0
      ..[7] = 0;
    expect(BleBatchAssembler().add(zeroTotal, now: now).invalid, isTrue);
  });

  test('rejects short/overlong final payload and inner version/kind mismatch',
      () {
    final frame = sensorFrame(rows: 1);
    final parts = fragments(frame);
    for (final tail in [
      Uint8List.sublistView(parts.last, 0, parts.last.length - 1),
      Uint8List.fromList([...parts.last, 0]),
    ]) {
      final assembler = BleBatchAssembler();
      for (final part in parts.take(parts.length - 1)) {
        assembler.add(part, now: now);
      }
      expect(assembler.add(tail, now: now).invalid, isTrue);
    }
    for (final offset in [0, 1]) {
      final badParts = fragments(frame);
      badParts[0][8 + offset] = 2;
      final assembler = BleBatchAssembler();
      BatchAssemblyResult? result;
      for (final part in badParts) {
        result = assembler.add(part, now: now);
      }
      expect(result!.invalid, isTrue);
      expect(result.frame, isNull);
    }
  });
}
