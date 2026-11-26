import 'dart:typed_data';

import 'protocol.dart';

class BatchAssemblyResult {
  final Uint8List? frame;
  final bool invalid;

  const BatchAssemblyResult({this.frame, this.invalid = false});
}

/// One bounded, ordered fragment assembly per characteristic/session.
/// Complete frame contents are validated by the typed decoder after assembly.
class BleBatchAssembler {
  BleBatchAssembler({this.expectedKind})
      : assert(
            expectedKind == null || (expectedKind >= 1 && expectedKind <= 4));

  final int? expectedKind;
  Uint8List? _buffer;
  DateTime? _startedAt;
  int _kind = 0;
  int _frameId = 0;
  int _count = 0;
  int _next = 0;
  int _payloadSize = 0;
  int _written = 0;

  void reset() {
    _buffer = null;
    _startedAt = null;
    _kind = _frameId = _count = _next = _payloadSize = _written = 0;
  }

  BatchAssemblyResult _reject() {
    reset();
    return const BatchAssemblyResult(invalid: true);
  }

  BatchAssemblyResult add(Uint8List bytes, {required DateTime now}) {
    if (bytes.isEmpty || bytes[0] != 0xf3) {
      reset();
      return BatchAssemblyResult(frame: bytes);
    }
    if (_startedAt != null &&
        now.difference(_startedAt!) >= const Duration(seconds: 1)) {
      reset();
    }
    if (bytes.length < 9) return _reject();
    final data = ByteData.sublistView(bytes);
    final kind = bytes[1];
    final id = data.getUint16(2, Endian.little);
    final index = bytes[4];
    final count = bytes[5];
    final total = data.getUint16(6, Endian.little);
    final payload = bytes.length - 8;
    if (index == 0) reset();
    if (kind < 1 ||
        kind > 4 ||
        (expectedKind != null && kind != expectedKind) ||
        count < 2 ||
        index >= count ||
        total > 512 ||
        !_validFrameLength(kind, total)) {
      return _reject();
    }
    if (index == 0) {
      // Nonfinal fragments must all have this payload width. The final one
      // must be positive and no larger, so reject impossible framing now.
      if ((count - 1) * payload >= total || count * payload < total) {
        return _reject();
      }
      _buffer = Uint8List(total);
      _startedAt = now;
      _kind = kind;
      _frameId = id;
      _count = count;
      _payloadSize = payload;
    }
    final buffer = _buffer;
    if (buffer == null ||
        kind != _kind ||
        id != _frameId ||
        count != _count ||
        total != buffer.length ||
        index != _next ||
        payload > _payloadSize ||
        (index < count - 1 && payload != _payloadSize) ||
        _written + payload > total) {
      return _reject();
    }
    buffer.setRange(_written, _written + payload, bytes, 8);
    _written += payload;
    _next++;
    if (_next != count) return const BatchAssemblyResult();
    if (_written != total || buffer[0] != 3 || buffer[1] != kind) {
      return _reject();
    }
    reset();
    return BatchAssemblyResult(frame: buffer);
  }

  static bool _validFrameLength(int kind, int total) {
    if (kind == 4) return DeviceStatus.isV3FrameLength(total);
    final rowSize = switch (kind) { 1 => 48, 2 => 44, 3 => 40, _ => 0 };
    return rowSize != 0 &&
        total > 28 &&
        (total - 28) % rowSize == 0 &&
        (total - 28) ~/ rowSize <= 8;
  }
}
