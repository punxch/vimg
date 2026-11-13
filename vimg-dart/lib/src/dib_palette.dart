import 'dart:typed_data';

import 'binary_file.dart';

/// Read the RGBQUAD color table following a Windows bitmap info header.
List<int> readDibPalette(BinaryFile file, int start, int end, int bits) {
  final palette = List<int>.filled(256, 0);
  if (end - start < 40) return palette;
  final header = ByteData.sublistView(file.read(start, 40));
  final table = start + header.getUint32(0, Endian.little);
  final declared = header.getUint32(32, Endian.little);
  final limit = 1 << bits;
  if (table < start + 40 || table > end || declared > limit) {
    throw const FormatException('Invalid bitmap palette');
  }
  final available = (end - table) ~/ 4;
  final colors = declared == 0 ? available.clamp(0, limit) : declared;
  if (colors > available) {
    throw const FormatException('Truncated bitmap palette');
  }
  final data = ByteData.sublistView(file.read(table, 4 * colors));
  for (var i = 0; i < colors; i++) {
    palette[i] = data.getUint32(4 * i, Endian.little) & 0xffffff;
  }
  return palette;
}
