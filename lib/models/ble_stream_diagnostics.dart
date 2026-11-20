import 'dart:typed_data';

import 'protocol.dart';

/// Notification counters are separate from decoded frames and sample records.
/// Ordering is tracked per glove, independently of UI/local-sample filtering.
class BleStreamDiagnostics {
  int packets = 0;
  int frames = 0;
  int samples = 0;
  int invalidPackets = 0;
  int sequenceGaps = 0;
  int repeatedOrOlder = 0;
  final Map<int, RawImuSample> _previous = {};
  DateTime? lastPacket;

  void reset() {
    packets = 0;
    frames = 0;
    samples = 0;
    invalidPackets = 0;
    sequenceGaps = 0;
    repeatedOrOlder = 0;
    _previous.clear();
    lastPacket = null;
  }

  void recordNotification(DateTime now) {
    packets++;
    lastPacket = now;
  }

  void recordMalformed() => invalidPackets++;

  void recordFrame(List<RawImuSample> entries) {
    frames++;
    samples += entries.length;
    for (final sample in entries) {
      final previous = _previous[sample.gloveId];
      if (previous != null && previous.version == sample.version) {
        final mask = sample.version == 2 ? 0xffff : 0xffffffff;
        final half = sample.version == 2 ? 0x8000 : 0x80000000;
        final delta = (sample.sequence - previous.sequence) & mask;
        if (delta == 0 || delta >= half) {
          repeatedOrOlder++;
          continue;
        }
        sequenceGaps += delta - 1;
      }
      _previous[sample.gloveId] = sample;
    }
  }

  /// Convenience for complete, unfragmented legacy or v3 notifications.
  void record(Uint8List bytes, DateTime now) {
    recordNotification(now);
    final entries = RawImuSample.decodeAll(bytes);
    if (entries == null) {
      recordMalformed();
    } else {
      recordFrame(entries);
    }
  }

  String describe(DateTime now) {
    final age = lastPacket == null
        ? 'none'
        : '${now.difference(lastPacket!).inMilliseconds}ms';
    return 'packets=$packets frames=$frames samples=$samples '
        'invalid=$invalidPackets sequenceGaps=$sequenceGaps '
        'repeatedOrOlder=$repeatedOrOlder lastPacketAge=$age';
  }
}
