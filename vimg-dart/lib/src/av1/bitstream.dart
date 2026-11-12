import 'dart:typed_data';

final class BitWriter {
  final _bytes = BytesBuilder(copy: false);
  var _partial = 0;
  var _remaining = 8;

  void write(int value, int bits) {
    assert(value >= 0 && value.bitLength <= bits);
    while (bits > 0) {
      final take = bits < _remaining ? bits : _remaining;
      bits -= take;
      _remaining -= take;
      _partial |= ((value >> bits) & ((1 << take) - 1)) << _remaining;
      if (_remaining == 0) {
        _bytes.addByte(_partial);
        _partial = 0;
        _remaining = 8;
      }
    }
  }

  Uint8List finish({bool trailingBit = false}) {
    if (trailingBit) write(1, 1);
    if (_remaining != 8) _bytes.addByte(_partial);
    return _bytes.takeBytes();
  }
}

Uint8List obu(int type, Uint8List payload) {
  var length = payload.length;
  final bytes = BytesBuilder(copy: false)..addByte((type << 3) | 2);
  while (length >= 128) {
    bytes.addByte((length & 127) | 128);
    length >>= 7;
  }
  bytes
    ..addByte(length)
    ..add(payload);
  return bytes.takeBytes();
}

/// Uncompressed AV1 syntax and the bit input to the symbol decoder.
final class Av1Bits {
  Av1Bits(this.data);

  final Uint8List data;
  var position = 0;

  int get remaining => data.length * 8 - position;

  int read(int count) {
    if (count < 0 || count > remaining)
      throw const FormatException('Truncated AV1 bitstream');
    var value = 0;
    while (count > 0) {
      final available = 8 - (position & 7);
      final take = count < available ? count : available;
      value =
          (value << take) |
          ((data[position >> 3] >> (available - take)) & ((1 << take) - 1));
      position += take;
      count -= take;
    }
    return value;
  }

  bool flag() => read(1) != 0;

  int signed(int count) {
    final value = read(count);
    final sign = 1 << (count - 1);
    return (value ^ sign) - sign;
  }

  int uvlc() {
    var zeros = 0;
    while (!flag()) {
      if (++zeros == 32) return 0xffffffff;
    }
    return (1 << zeros) - 1 + read(zeros);
  }

  int uniform(int count) {
    final width = count.bitLength;
    final short = (1 << width) - count;
    final value = read(width - 1);
    return value < short ? value : 2 * value - short + read(1);
  }

  void align() {
    if (read(-position & 7) != 0)
      throw const FormatException('Invalid AV1 alignment bits');
  }

  void trailing() {
    if (read(1) != 1)
      throw const FormatException('Missing AV1 trailing one bit');
    align();
    while (remaining > 0) {
      if (read(8) != 0)
        throw const FormatException('Invalid AV1 trailing bytes');
    }
  }
}

typedef Av1Obu = ({int type, int temporalId, int spatialId, Uint8List payload});

/// OBU framing used in ISO media samples and low-overhead elementary streams.
Iterable<Av1Obu> readAv1Obus(Uint8List data) sync* {
  var offset = 0;
  int byte() {
    if (offset == data.length) throw const FormatException('Truncated AV1 OBU');
    return data[offset++];
  }

  while (offset < data.length) {
    final header = byte();
    if (header & 0x81 != 0)
      throw const FormatException('Invalid AV1 OBU header');
    final type = (header >> 3) & 15;
    final extension = header & 4 != 0 ? byte() : 0;
    if (header & 4 != 0) {
      if (extension & 7 != 0)
        throw const FormatException('Invalid AV1 OBU extension');
    }
    var length = data.length - offset;
    if (header & 2 != 0) {
      length = 0;
      for (var i = 0; i < 8; i++) {
        final part = byte();
        length |= (part & 127) << (7 * i);
        if (part & 128 == 0) break;
        if (i == 7) throw const FormatException('Invalid AV1 OBU size');
      }
    }
    if (length > data.length - offset)
      throw const FormatException('AV1 OBU exceeds its sample');
    yield (
      type: type,
      temporalId: extension >> 5,
      spatialId: (extension >> 3) & 3,
      payload: Uint8List.sublistView(data, offset, offset + length),
    );
    offset += length;
  }
}
