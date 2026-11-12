import 'dart:typed_data';

/// Bit reader for H.264 raw byte sequence payloads (§7.2). It also supplies
/// the raw bits used by CABAC once the slice header has been consumed.
final class Rbsp {
  Rbsp(this.bytes);

  factory Rbsp.fromNal(Uint8List nal) {
    if (nal.length < 2 || nal.first & 0x80 != 0) {
      throw const FormatException('Invalid H.264 NAL header');
    }
    final output = Uint8List(nal.length - 1);
    var written = 0;
    var zeroes = 0;
    for (var i = 1; i < nal.length; i++) {
      final byte = nal[i];
      if (zeroes == 2 && byte == 3) {
        if (i + 1 == nal.length || nal[i + 1] > 3) {
          throw const FormatException(
            'Invalid H.264 emulation prevention byte',
          );
        }
        zeroes = 0;
        continue;
      }
      output[written++] = byte;
      zeroes = byte == 0 ? zeroes + 1 : 0;
    }
    return Rbsp(Uint8List.sublistView(output, 0, written));
  }

  final Uint8List bytes;
  var position = 0;

  int get remaining => bytes.length * 8 - position;

  int bit() {
    if (remaining <= 0)
      throw const FormatException('Truncated H.264 bitstream');
    final current = position++;
    return (bytes[current >> 3] >> (7 - (current & 7))) & 1;
  }

  bool flag() => bit() == 1;

  int read(int count) {
    if (count < 0 || count > remaining) {
      throw const FormatException('Truncated H.264 field');
    }
    var value = 0;
    while (count > 0) {
      final available = 8 - (position & 7);
      final take = count < available ? count : available;
      final byte = bytes[position >> 3];
      value =
          (value << take) | ((byte >> (available - take)) & ((1 << take) - 1));
      position += take;
      count -= take;
    }
    return value;
  }

  void skip(int count) {
    if (count < 0 || count > remaining) {
      throw const FormatException('Truncated H.264 field');
    }
    position += count;
  }

  int ue([int maximum = 0x7fffffff]) {
    var zeroes = 0;
    while (bit() == 0) {
      if (++zeroes > 31)
        throw const FormatException('Oversized H.264 Exp-Golomb code');
    }
    final value = (1 << zeroes) - 1 + read(zeroes);
    if (value > maximum)
      throw const FormatException('H.264 field is out of range');
    return value;
  }

  int se() {
    final value = ue();
    return value.isOdd ? (value + 1) >> 1 : -(value >> 1);
  }

  void align(int padding) {
    while (position & 7 != 0) {
      if (bit() != padding)
        throw const FormatException('Invalid H.264 byte alignment');
    }
  }

  bool get hasMoreData {
    if (remaining <= 0) return false;
    final saved = position;
    try {
      if (!flag()) return true;
      while (remaining > 0) {
        if (flag()) return true;
      }
      return false;
    } finally {
      position = saved;
    }
  }
}
