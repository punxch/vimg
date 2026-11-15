part of 'ffv1.dart';

void _decodeBayerSlice(
  _RangeDecoder range,
  _SliceHeader header,
  _SliceState state,
  _RiceReader? rice,
  List<int> mosaic,
  int stride,
  (int, int, int, int) rectangle,
) {
  final (left, top, width, height) = rectangle;
  if ((left | top | width | height).isOdd) {
    throw const FormatException('Unaligned FFV1 Bayer slice');
  }
  final planes = [
    for (final (plane, context) in [0, 2, 1, 1].indexed)
      _ScanLines(
        width ~/ 2,
        plane == 0 || header.raw ? 16 : 17,
        range,
        header.tables[context],
        state.contexts[context],
        rice: rice,
        raw: header.raw,
      ),
  ];
  const center = 1 << 16;
  for (var row = 0; row < height; row += 2) {
    final samples = [for (final plane in planes) plane.decode()];
    var offset = (top + row) * stride + left;
    for (var x = 2; x < width ~/ 2 + 2; x++, offset += 2) {
      var greenRed = samples[0][x];
      var greenBlue = samples[1][x];
      var blue = samples[2][x];
      var red = samples[3][x];
      if (!header.raw) {
        blue -= center;
        red -= center;
        final green =
            greenRed -
            ((blue * header.blueWeight + red * header.redWeight) >> 2);
        blue += green;
        red += green;
        final difference = greenBlue - center;
        greenBlue = green - (difference >> 1);
        greenRed = greenBlue + difference;
      }
      mosaic[offset] = red & 65535;
      mosaic[offset + 1] = greenRed & 65535;
      mosaic[offset + stride] = greenBlue & 65535;
      mosaic[offset + stride + 1] = blue & 65535;
    }
  }
}

/// Interpolate each missing component from adjacent samples of that color.
(Uint16List, Uint16List, Uint16List) _demosaicRggb(
  List<int> mosaic,
  int width,
  int height,
) {
  final green = Uint16List(mosaic.length);
  final blue = Uint16List(mosaic.length);
  final red = Uint16List(mosaic.length);
  for (var y = 0; y < height; y++) {
    final row = y * width;
    final above = (y == 0 ? 1 : y - 1) * width;
    final below = (y == height - 1 ? y - 1 : y + 1) * width;
    for (var x = 0; x < width; x++) {
      final left = x == 0 ? 1 : x - 1;
      final right = x == width - 1 ? x - 1 : x + 1;
      final offset = row + x;
      final here = mosaic[offset];
      final horizontal = mosaic[row + left] + mosaic[row + right];
      final vertical = mosaic[above + x] + mosaic[below + x];
      if (x.isOdd == y.isOdd) {
        final diagonal =
            mosaic[above + left] +
            mosaic[above + right] +
            mosaic[below + left] +
            mosaic[below + right];
        green[offset] = (horizontal + vertical + 2) >> 2;
        red[offset] = y.isEven ? here : (diagonal + 2) >> 2;
        blue[offset] = y.isOdd ? here : (diagonal + 2) >> 2;
      } else {
        green[offset] = here;
        red[offset] = ((y.isEven ? horizontal : vertical) + 1) >> 1;
        blue[offset] = ((y.isOdd ? horizontal : vertical) + 1) >> 1;
      }
    }
  }
  return (green, blue, red);
}
