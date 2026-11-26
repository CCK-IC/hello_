import 'dart:collection';
import 'dart:typed_data';

import 'protocol.dart';
import 'sample_timeline.dart';

/// AUX v1 singleton or v3 fixed-slot batch acquisition record.
class AdcSample {
  final int version;
  final int gloveId;
  final int flags;
  final int activeChannelCount;
  final int? measuredRateHz;
  final int sequence;
  final int timestampMs;
  final List<int> channels;

  AdcSample._(this.sequence, this.timestampMs, List<int> channels,
      {this.version = 1,
      this.gloveId = 0,
      this.flags = 1,
      this.activeChannelCount = 8,
      this.measuredRateHz})
      : channels = List.unmodifiable(channels);

  bool get sampleValid => (flags & 1) != 0;

  static AdcSample? decode(Uint8List bytes) {
    final samples = decodeAll(bytes);
    if (samples == null) return null;
    for (final sample in samples.reversed) {
      if (sample.gloveId == 0) return sample;
    }
    return null;
  }

  static List<AdcSample>? decodeAll(Uint8List bytes) {
    if (bytes.isNotEmpty && bytes[0] == 3) {
      if (!isValidV3SensorFrame(bytes, kind: 3)) return null;
      final data = ByteData.sublistView(bytes);
      final samples = <AdcSample>[];
      for (var row = 0; row < bytes[3]; row++) {
        for (var glove = 0; glove < 2; glove++) {
          if ((bytes[2] & (1 << glove)) == 0) continue;
          final meta = 4 + glove * 12;
          final o = 28 + (row * 2 + glove) * 20;
          samples.add(AdcSample._(
            (data.getUint32(meta, Endian.little) + bytes[o]) & 0xffffffff,
            (data.getUint32(meta + 4, Endian.little) +
                    data.getUint16(o + 1, Endian.little)) &
                0xffffffff,
            List.generate(
                8, (i) => data.getInt16(o + 4 + i * 2, Endian.little)),
            version: 3,
            gloveId: glove,
            flags: bytes[o + 3],
            activeChannelCount: bytes[meta + 10],
            measuredRateHz: data.getUint16(meta + 8, Endian.little),
          ));
        }
      }
      return samples;
    }
    final sample = _decodeLegacy(bytes);
    return sample == null ? null : [sample];
  }

  static AdcSample? _decodeLegacy(Uint8List bytes) {
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
  final DateTime? sampleTime;
  DateTime get sampledAt => sampleTime ?? receivedAt;
  const AdcHistoryPoint(this.receivedAt, this.sample, {this.sampleTime});
}

/// Bounded in arrival order; call clear when the connection/device changes.
class AdcHistory {
  int _maxSamples;
  final ListQueue<AdcHistoryPoint> _points = ListQueue();
  final SampleTimeline _timeline = SampleTimeline();

  AdcHistory({int maxSamples = 6000})
      : assert(maxSamples > 0),
        _maxSamples = maxSamples;

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
  AdcHistoryPoint? get latest => _points.isEmpty ? null : _points.last;

  /// Returns the visible window, keeping the latest reading for its label.
  List<AdcHistoryPoint> pointsSince(DateTime cutoff) {
    var low = 0;
    var high = _points.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (_points.elementAt(mid).sampledAt.isBefore(cutoff)) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    if (low == _points.length && low > 0) low--;
    return List.generate(
        _points.length - low, (i) => _points.elementAt(low + i),
        growable: false);
  }

  /// Returns false for malformed or unsupported packets.
  bool addPacket(Uint8List bytes,
      {DateTime? receivedAt, void Function(AdcHistoryPoint)? onPoint}) {
    final decoded = AdcSample.decodeAll(bytes);
    if (decoded == null) return false;
    final samples = decoded.where((sample) => sample.gloveId == 0).toList();
    final arrival = receivedAt ?? DateTime.now();
    final isBatch = samples.isNotEmpty && samples.first.version == 3;
    if (!isBatch) _timeline.reset();
    final times = isBatch
        ? _timeline.mapBatch(
            samples.map((sample) => sample.timestampMs).toList(), arrival)
        : null;
    for (var i = 0; i < samples.length; i++) {
      final point = AdcHistoryPoint(arrival, samples[i], sampleTime: times?[i]);
      _points.addLast(point);
      onPoint?.call(point);
    }
    while (_points.length > _maxSamples) {
      _points.removeFirst();
    }
    return true;
  }

  void clear() {
    _points.clear();
    _timeline.reset();
  }
}
