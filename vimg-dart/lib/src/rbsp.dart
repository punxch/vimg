import 'dart:typed_data';

/// Bit reader for H.264 and HEVC raw byte sequence payloads.
final class Rbsp {
  Rbsp(this.bytes, {this.codec = 'H.264', this.preventionOffsets = const []});

  factory Rbsp.fromNal(
    Uint8List nal, {
    int headerBytes = 1,
    String codec = 'H.264',
    bool trackPrevention = false,
  }) {
    if (nal.length <= headerBytes || nal.first & 0x80 != 0) {
      throw FormatException('Invalid $codec NAL header');
    }
    final output = Uint8List(nal.length - headerBytes);
    var written = 0;
    var zeroes = 0;
    List<int>? prevention;
    for (var i = headerBytes; i < nal.length; i++) {
      final byte = nal[i];
      if (zeroes == 2 && byte == 3) {
        // A final cabac_zero_word is encoded as 00 00 03.
        if (i + 1 < nal.length && nal[i + 1] > 3) {
          throw FormatException('Invalid $codec emulation prevention byte');
        }
        if (trackPrevention) (prevention ??= []).add(i - headerBytes);
        zeroes = 0;
        continue;
      }
      output[written++] = byte;
      zeroes = byte == 0 ? zeroes + 1 : 0;
    }
    return Rbsp(
      Uint8List.sublistView(output, 0, written),
      codec: codec,
      preventionOffsets: prevention ?? const [],
    );
  }

  final Uint8List bytes;
  final String codec;
  final List<int> preventionOffsets;
  var position = 0;

  int get remaining => bytes.length * 8 - position;

  int bit() {
    if (remaining <= 0) throw FormatException('Truncated $codec bitstream');
    final current = position++;
    return (bytes[current >> 3] >> (7 - (current & 7))) & 1;
  }

  bool flag() => bit() == 1;

  /// AVC and HEVC use the same VUI sample aspect ratio codes.
  double readVuiSampleAspect() {
    if (!flag()) return 1;
    final id = read(8);
    if (id == 255) {
      final width = read(16), height = read(16);
      return width == 0 || height == 0 ? 1 : width / height;
    }
    const ratios = [
      (1, 1),
      (1, 1),
      (12, 11),
      (10, 11),
      (16, 11),
      (40, 33),
      (24, 11),
      (20, 11),
      (32, 11),
      (80, 33),
      (18, 11),
      (15, 11),
      (64, 33),
      (160, 99),
      (4, 3),
      (3, 2),
      (2, 1),
    ];
    if (id >= ratios.length) return 1;
    final (width, height) = ratios[id];
    return width / height;
  }

  int read(int count) {
    if (count < 0 || count > remaining) {
      throw FormatException('Truncated $codec field');
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
      throw FormatException('Truncated $codec field');
    }
    position += count;
  }

  int ue([int maximum = 0x7fffffff]) {
    var zeroes = 0;
    while (bit() == 0) {
      if (++zeroes > 31)
        throw FormatException('Oversized $codec Exp-Golomb code');
    }
    final value = (1 << zeroes) - 1 + read(zeroes);
    if (value > maximum) throw FormatException('$codec field is out of range');
    return value;
  }

  int se() {
    final value = ue();
    return value.isOdd ? (value + 1) >> 1 : -(value >> 1);
  }

  void align(int padding) {
    while (position & 7 != 0) {
      if (bit() != padding)
        throw FormatException('Invalid $codec byte alignment');
    }
  }

  void readStopBit() {
    if (!flag()) throw FormatException('Missing $codec RBSP stop bit');
    align(0);
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
