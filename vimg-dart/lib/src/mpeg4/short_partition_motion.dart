part of 'decoder.dart';

typedef _H263PartitionMotionSlot = ({_H263PartitionBlock block, int index});
typedef _H263PartitionMotionValue = ({_Vector vector, int end});

const _motionMarkerBits = 10;
const _motionMarker = 1;

void _readPartitionMotion(
  Rbsp bits,
  int end,
  List<_H263PartitionMotionSlot> slots,
) {
  final start = bits.position;
  final reader = _H263ForwardMotion(bits);
  final forward = <_H263PartitionMotionValue>[];
  var last = _zeroVector;
  var hasSecondary = false;
  _Vector? repeated;
  try {
    for (final slot in slots) {
      final delta = reader.read();
      if (bits.position > end) {
        throw const FormatException(
          'H.263+ motion partition exceeds its slice',
        );
      }
      if (slot.index < 0) {
        forward.add((vector: delta, end: bits.position));
        hasSecondary = true;
      } else {
        last = (x: last.x + delta.x, y: last.y + delta.y);
        forward.add((vector: last, end: bits.position));
      }
    }
    if (slots.length > 1) repeated = reader.read();
    if (bits.position + _motionMarkerBits > end ||
        bits.read(_motionMarkerBits) != _motionMarker) {
      throw const FormatException('Invalid H.263+ motion partition marker');
    }
  } on FormatException {
    if (!hasSecondary && repeated != null && repeated == last) rethrow;
    final recovered = _recoverPartitionMotion(bits, start, end, slots, forward);
    if (recovered == null) rethrow;
    _storePartitionMotion(slots, recovered);
    return;
  }
  // The coding is otherwise consistent at this length. An unequal anchor
  // does not indicate whether the primary chain or the repeated value failed.
  if (!hasSecondary && repeated != null && repeated != last) {
    throw const FormatException(
      'H.263+ motion partition has an inconsistent last vector',
    );
  }
  _storePartitionMotion(slots, forward.map((value) => value.vector));
}

void _storePartitionMotion(
  List<_H263PartitionMotionSlot> slots,
  Iterable<_Vector?> values,
) {
  for (final (i, value) in values.indexed) {
    if (value == null) continue;
    final (:block, :index) = slots[i];
    if (index < 0) {
      block.delta = value;
    } else {
      block.motion[index] = value;
    }
  }
}

List<_Vector?>? _recoverPartitionMotion(
  Rbsp bits,
  int start,
  int end,
  List<_H263PartitionMotionSlot> slots,
  List<_H263PartitionMotionValue> forward,
) {
  final marker = _findPartitionMotionMarker(bits, start, end);
  if (marker == null) return null;

  // A partial forward parse can only contribute vectors before the marker.
  final prefix = forward.takeWhile((value) => value.end <= marker).length;
  final interrupted = prefix < slots.length;
  final floor = interrupted && prefix > 0 ? forward[prefix - 1].end : start;
  final reconstructed = List<_Vector?>.filled(slots.length, null);
  var suffix = slots.length;
  var suffixBoundary = marker;
  if (slots.length > 1 && slots.last.index >= 0) {
    final reader = _H263ReverseMotion(bits.bytes, marker, floor);
    try {
      var current = reader.read(); // LMVV, coded relative to zero.
      final first = interrupted ? prefix : 0;
      for (var i = slots.length - 1; i >= first; i--) {
        final primary = slots[i].index >= 0;
        if (primary) {
          // The motion for this slot is known before reading its delta.
          // Even a broken delta can still leave this motion recoverable.
          reconstructed[i] = current;
          suffix = i;
          suffixBoundary = reader.position;
        }
        final delta = reader.read();
        if (primary) {
          current = (x: current.x - delta.x, y: current.y - delta.y);
        }
      }
    } on FormatException {
      // Keep the suffix read from the anchor before the gap.
    }
  }
  if (!interrupted && suffix == slots.length) return null;
  for (var i = 0; i < math.min(prefix, suffix); i++) {
    if (forward[i].end > suffixBoundary) break;
    reconstructed[i] = forward[i].vector;
  }
  bits.position = marker + _motionMarkerBits;
  return reconstructed;
}

int? _findPartitionMotionMarker(Rbsp bits, int start, int end) {
  // Table D.3 and the inserted bits limit runs inside an intact motion
  // partition. The first nine-zero marker ends that partition.
  bits.position = start;
  var word = 0;
  while (bits.position < end) {
    word = ((word << 1) | bits.bit()) & ((1 << _motionMarkerBits) - 1);
    if (bits.position - start >= _motionMarkerBits && word == _motionMarker) {
      return bits.position - _motionMarkerBits;
    }
  }
  return null;
}

final class _H263ForwardMotion {
  _H263ForwardMotion(this.bits);

  final Rbsp bits;
  var _pendingOne = false;

  _Vector read() => (x: _component(), y: _component());

  int _component() {
    final value = h263ReversibleComponent(bits);
    if (value == 1 && _pendingOne) {
      h263Marker(bits);
      _pendingOne = false;
    } else {
      _pendingOne = value == 1;
    }
    return value;
  }
}

final class _H263ReverseMotion {
  _H263ReverseMotion(this.bytes, this.position, this.floor);

  final Uint8List bytes;
  final int floor;
  int position;

  _Vector read() {
    final y = _component(), x = _component();
    return (x: x, y: y);
  }

  int _component() {
    if (_bit() == 1) {
      // A one after six motion bits of zero is the escape following two
      // consecutive +1 codewords. Otherwise it is a zero-delta codeword.
      if (position - floor < 6) return 0;
      for (var i = position - 6; i < position; i++) {
        if (_at(i) != 0) return 0;
      }
      _bit(); // Read the end bit of the second +1 codeword.
    }
    var value = _bit();
    var length = 1;
    while (_bit() == 1) {
      if (length >= 14) {
        throw const FormatException('Oversized H.263 reversible VLC value');
      }
      value |= _bit() << length++;
    }
    value |= 1 << length;
    return value.isOdd ? -(value >> 1) : value >> 1;
  }

  int _bit() {
    if (position <= floor) {
      throw const FormatException('Truncated H.263+ reverse motion partition');
    }
    return _at(--position);
  }

  int _at(int position) => (bytes[position >> 3] >> (7 - (position & 7))) & 1;
}
