import 'dart:typed_data';

/// Read the RGBQUAD color table following a Windows bitmap info header.
List<int> readDibPalette(
  int length,
  Uint8List Function(int offset, int size) read,
  int bits,
) {
  final palette = List<int>.filled(256, 0);
  if (length < 40) return palette;
  final header = ByteData.sublistView(read(0, 40));
  final table = header.getUint32(0, Endian.little);
  final declared = header.getUint32(32, Endian.little);
  final limit = 1 << bits;
  if (table < 40 || table > length || declared > limit) {
    throw const FormatException('Invalid bitmap palette');
  }
  final available = (length - table) ~/ 4;
  final colors = declared == 0 ? available.clamp(0, limit) : declared;
  if (colors > available) {
    throw const FormatException('Truncated bitmap palette');
  }
  final data = ByteData.sublistView(read(table, 4 * colors));
  for (var i = 0; i < colors; i++) {
    palette[i] = data.getUint32(4 * i, Endian.little) & 0xffffff;
  }
  return palette;
}
