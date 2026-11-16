part of 'decoder.dart';

typedef _TextureSlot = ({int index, _Events codes, int first});

extension _ReversibleTexture on _VopDecoder {
  void _readReversibleTexture(int start, List<_PartitionMacroblock?> blocks) {
    final textureStart = _bits.position;
    final next = start + blocks.length;
    try {
      _reconstructPartition(start, blocks);
      if (next == _columns * picture.rows) return;
      final position = _bits.position;
      final marker = (position >> 3) + 1;
      if (_partitionStuffingStart(_bits.bytes, marker) == position &&
          _isPartitionBoundary(_bits, marker, next)) {
        _bits.position = position;
        return;
      }
      throw const FormatException('Invalid MPEG-4 texture partition end');
    } on FormatException {
      final end = _findTextureEnd(textureStart, next);
      if (end == null) rethrow;
      final texture = _recoverTexture(textureStart, end, blocks);
      if (texture == null) rethrow;
      // Replay prediction and reconstruction in raster order. Motion, DC and
      // coded-block flags come from the intact preceding partitions.
      _reconstructPartition(start, blocks, texture);
      _bits.position = end;
    }
  }

  int? _findTextureEnd(int start, int next) {
    final bytes = _bits.bytes;
    if (next == _columns * picture.rows) {
      final end = _partitionStuffingStart(bytes, bytes.length);
      return end != null && end >= start ? end : null;
    }
    final probe = Rbsp(bytes, codec: _bits.codec);
    for (var offset = (start >> 3) + 1; offset + 2 < bytes.length; offset++) {
      if (bytes[offset] != 0 || bytes[offset + 1] != 0) continue;
      final end = _partitionStuffingStart(bytes, offset);
      if (end != null &&
          end >= start &&
          _isPartitionBoundary(probe, offset, next)) {
        return end;
      }
    }
    return null;
  }

  bool _isPartitionBoundary(Rbsp bits, int offset, int next) {
    bits.position = offset * 8;
    final addressBits = (_columns * picture.rows - 1).bitLength;
    return bits.remaining >=
            _packetMarkerZeroes +
                1 +
                addressBits +
                header.volume.quantBits +
                1 &&
        _readPacketAddress(bits) == next;
  }

  List<List<_DctEvent>?>? _recoverTexture(
    int start,
    int end,
    List<_PartitionMacroblock?> blocks,
  ) {
    final slots = <_TextureSlot>[
      for (final (i, block) in blocks.indexed)
        if (block != null)
          for (var j = 0; j < 6; j++)
            if (block.pattern & (32 >> j) != 0)
              (
                index: i * 6 + j,
                codes: block.intra
                    ? _intraReversibleEvents
                    : _interReversibleEvents,
                first: block.dc == null ? -1 : 0,
              ),
    ];
    final texture = List<List<_DctEvent>?>.filled(blocks.length * 6, null);
    final forward = Rbsp(_bits.bytes, codec: _bits.codec, end: end)
      ..position = start;
    var firstMissing = 0;
    var floor = start;
    try {
      for (final slot in slots) {
        final textureEvents = <_DctEvent>[];
        var position = slot.first;
        while (true) {
          final event = slot.codes.read(forward);
          position = _nextCoefficient(position, event);
          textureEvents.add(event);
          if (event.last) break;
        }
        texture[slot.index] = textureEvents;
        floor = forward.position;
        firstMissing++;
      }
      // Extra data after a full set of blocks leaves their alignment unclear.
      if (floor != end) return null;
    } on FormatException {
      final reverse = _ReverseTextureBits(_bits.bytes, floor, end);
      for (var i = slots.length - 1; i >= firstMissing; i--) {
        final slot = slots[i];
        final events = _readReverseBlock(reverse, slot, i == firstMissing);
        if (events == null) break;
        texture[slot.index] = events;
      }
    }
    return texture;
  }
}

int? _partitionStuffingStart(Uint8List bytes, int offset) {
  if (offset <= 0 || offset > bytes.length) return null;
  var byte = bytes[offset - 1];
  if (byte == 0xff) return null;
  var width = 1;
  while (byte.isOdd) {
    byte >>= 1;
    width++;
  }
  return offset * 8 - width;
}

List<_DctEvent>? _readReverseBlock(
  _ReverseTextureBits bits,
  _TextureSlot slot,
  bool firstRemaining,
) {
  try {
    final last = slot.codes.readReverse(bits);
    if (!last.last) return null;
    final reversed = [last];
    var coefficient = _nextCoefficient(slot.first, last);
    while (bits.position > bits.floor) {
      final position = bits.position;
      final event = slot.codes.readReverse(bits);
      // Intra and inter tables assign LAST to the same codewords. Leave
      // this event for the preceding block, which can use the other table.
      if (event.last) {
        if (firstRemaining) return null;
        bits.position = position;
        return reversed.reversed.toList();
      }
      coefficient = _nextCoefficient(coefficient, event);
      reversed.add(event);
    }
    if (firstRemaining) return reversed.reversed.toList();
  } on FormatException {
    // Without the preceding LAST, the current block may be incomplete.
  }
  return null;
}

final class _ReverseTextureBits {
  _ReverseTextureBits(this.bytes, this.floor, this.position);

  final Uint8List bytes;
  final int floor;
  int position;

  int read(int count) {
    if (position - count < floor) {
      throw const FormatException('Truncated MPEG-4 reverse texture');
    }
    var value = 0;
    for (var i = 0; i < count; i++) {
      final at = --position;
      value |= ((bytes[at >> 3] >> (7 - (at & 7))) & 1) << i;
    }
    return value;
  }
}
