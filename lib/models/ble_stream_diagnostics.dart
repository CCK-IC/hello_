import 'dart:typed_data';

import 'protocol.dart';

/// Counts received packets independently of the UI's sample ordering filter.
class BleStreamDiagnostics {
  int packets = 0;
  int invalidPackets = 0;
  int sequenceGaps = 0;
  int repeatedOrOlder = 0;
  RawImuSample? _previous;
  DateTime? lastPacket;

  void reset() {
    packets = 0;
    invalidPackets = 0;
    sequenceGaps = 0;
    repeatedOrOlder = 0;
    _previous = null;
    lastPacket = null;
  }

  void record(Uint8List bytes, DateTime now) {
    packets++;
    lastPacket = now;
    final sample = RawImuSample.decode(bytes);
    if (sample == null) {
      invalidPackets++;
      return;
    }
    final previous = _previous;
    if (previous != null && previous.version == sample.version) {
      final mask = sample.version == 2 ? 0xffff : 0xffffffff;
      final half = sample.version == 2 ? 0x8000 : 0x80000000;
      final delta = (sample.sequence - previous.sequence) & mask;
      if (delta == 0 || delta >= half) {
        repeatedOrOlder++;
        return;
      } else {
        sequenceGaps += delta - 1;
      }
    }
    _previous = sample;
  }

  String describe(DateTime now) {
    final age = lastPacket == null
        ? 'none'
        : '${now.difference(lastPacket!).inMilliseconds}ms';
    return 'packets=$packets invalid=$invalidPackets sequenceGaps=$sequenceGaps '
        'repeatedOrOlder=$repeatedOrOlder lastPacketAge=$age';
  }
}
