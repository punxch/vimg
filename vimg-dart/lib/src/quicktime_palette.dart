import 'dart:typed_data';

List<int> quickTimePalette(ByteData data, int codedDepth, int depth) {
  final count = 1 << depth;
  if (data.getUint16(76) == 0) {
    if (data.lengthInBytes < 86) {
      throw const FormatException('Missing QuickTime color table');
    }
    final entries = data.getUint16(84) + 1;
    if (entries > count || data.lengthInBytes < 86 + entries * 8) {
      throw const FormatException('Invalid QuickTime color table');
    }
    final colors = List.filled(count, 0);
    for (var i = 0; i < entries; i++) {
      final offset = 86 + i * 8;
      colors[i] =
          data.getUint8(offset + 2) << 16 |
          data.getUint8(offset + 4) << 8 |
          data.getUint8(offset + 6);
    }
    return colors;
  }
  if (depth == 1) return const [0xffffff, 0];
  if (codedDepth & 32 != 0) {
    final step = 256 ~/ (count - 1);
    return [
      for (var i = 0; i < count; i++) (255 - i * step).clamp(0, 255) * 0x010101,
    ];
  }
  if (depth == 2) return const [0xffffff, 0xacacac, 0x555555, 0];
  if (depth == 4) {
    return const [
      0xffffff,
      0xfcf305,
      0xff6402,
      0xdd0806,
      0xf20884,
      0x4600a5,
      0x0000d4,
      0x02abea,
      0x1fb714,
      0x006411,
      0x562c05,
      0x90713a,
      0xc0c0c0,
      0x808080,
      0x404040,
      0,
    ];
  }
  const cube = [255, 204, 153, 102, 51, 0];
  const ramp = [238, 221, 187, 170, 136, 119, 85, 68, 34, 17];
  return [
    for (final r in cube)
      for (final g in cube)
        for (final b in cube)
          if (r | g | b != 0) r << 16 | g << 8 | b,
    for (final channel in [0x010000, 0x000100, 1, 0x010101])
      for (final value in ramp) channel * value,
    0,
  ];
}
