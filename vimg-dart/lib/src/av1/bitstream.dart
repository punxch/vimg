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
