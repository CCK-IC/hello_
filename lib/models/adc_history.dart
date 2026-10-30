import 'dart:collection';
import 'dart:typed_data';

/// AUX v1, as encoded by firmware ble_encode_aux (22 bytes).
class AdcSample {
  final int sequence;
  final int timestampMs;
  final List<int> channels;

  AdcSample._(this.sequence, this.timestampMs, List<int> channels)
      : channels = List.unmodifiable(channels);

  static AdcSample? decode(Uint8List bytes) {
    if (bytes.length != 22 || bytes[0] != 1) return null;
    final data = ByteData.sublistView(bytes);
    return AdcSample._(
      bytes[1],
      data.getUint32(2, Endian.little),
      List.generate(8, (i) => data.getInt16(6 + i * 2, Endian.little)),
    );
  }
}

class AdcHistoryPoint {
  final DateTime receivedAt;
  final AdcSample sample;
  const AdcHistoryPoint(this.receivedAt, this.sample);
}

/// Bounded in arrival order; call clear when the connection/device changes.
class AdcHistory {
  int _maxSamples;
  final ListQueue<AdcHistoryPoint> _points = ListQueue();

  AdcHistory({int maxSamples = 6000})
      : assert(maxSamples > 0), _maxSamples = maxSamples;

  int get maxSamples => _maxSamples;
  set maxSamples(int value) {
    if (value <= 0) throw ArgumentError.value(value, 'maxSamples');
    _maxSamples = value;
    while (_points.length > _maxSamples) {
      _points.removeFirst();
    }
  }

  List<AdcHistoryPoint> get points => List.unmodifiable(_points);
  bool get isEmpty => _points.isEmpty;

  /// Returns the visible window, keeping the latest reading for its label.
  List<AdcHistoryPoint> pointsSince(DateTime cutoff) {
    var low = 0;
    var high = _points.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (_points.elementAt(mid).receivedAt.isBefore(cutoff)) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    if (low == _points.length && low > 0) low--;
    return List.generate(_points.length - low, (i) => _points.elementAt(low + i),
        growable: false);
  }

  /// Returns false for malformed or unsupported packets.
  bool addPacket(Uint8List bytes, {DateTime? receivedAt}) {
    final sample = AdcSample.decode(bytes);
    if (sample == null) return false;
    _points.addLast(AdcHistoryPoint(receivedAt ?? DateTime.now(), sample));
    while (_points.length > _maxSamples) {
      _points.removeFirst();
    }
    return true;
  }

  void clear() => _points.clear();
}
