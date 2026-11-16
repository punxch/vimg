part of 'decoder.dart';

H263Picture _h263AlignReference(H263Picture source, {required bool reduced}) {
  final format = source.format;
  final alignment = reduced ? 32 : 16;
  final width = (format.width + alignment - 1) & -alignment;
  final height = (format.height + alignment - 1) & -alignment;
  if (source.stride == width && source.rows * 16 == height) return source;
  if (source._referencePixels case final pixels?) {
    return H263Picture._reference(
      format,
      pixels,
      reduced: reduced,
      subPictures: source._subPictures,
    ).._segments = source._segments;
  }
  final target = H263Picture._(format, reduced: reduced);
  target._segments = source._segments;
  for (var plane = 0; plane < 3; plane++) {
    final sub = plane == 0 ? 0 : 1;
    final input = source.planes[plane], output = target.planes[plane];
    final oldStride = source.stride >> sub, stride = width >> sub;
    final oldRows = source.rows * 16 >> sub, rows = height >> sub;
    final copied = math.min(oldStride, stride);
    for (var y = 0; y < rows; y++) {
      final start = y * stride;
      final from = math.min(y, oldRows - 1) * oldStride;
      output.setRange(start, start + copied, input, from);
      output.fillRange(
        start + copied,
        start + stride,
        input[from + copied - 1],
      );
    }
  }
  return target;
}

_Vector _h263ExpandVector(_Vector pseudo) {
  // Both domains use half-pixel units. The nonzero mapping is monotonic, so
  // median predictors can use the same stored pseudo-vectors as direct mode.
  int expand(int value) => 2 * value - value.sign;
  return (x: expand(pseudo.x), y: expand(pseudo.y));
}

extension _H263Prediction on _Mpeg4MotionCompensation {
  void predictH263(
    H263Picture output,
    H263Picture reference,
    int x,
    int y,
    List<_Vector> vectors, {
    required bool reduced,
    bool noRound = false,
    bool average = false,
    _MotionBounds? bounds,
    bool extend = true,
    List<H263Picture>? lumaReferences,
  }) {
    final blockSize = reduced ? 16 : 8;
    final physical = reduced
        ? vectors.map(_h263ExpandVector).toList()
        : vectors;
    if (!extend && bounds != null) {
      final size = physical.length == 4 ? blockSize : blockSize * 2;
      for (final (i, vector) in physical.indexed) {
        final left = 2 * blockSize * (2 * x + (i & 1)) + vector.x;
        final top = 2 * blockSize * (2 * y + (i >> 1)) + vector.y;
        if (left < 2 * bounds.left ||
            top < 2 * bounds.top ||
            left + 2 * size > 2 * bounds.right ||
            top + 2 * size > 2 * bounds.bottom) {
          throw const FormatException(
            'H.263+ motion vector crosses an independent segment',
          );
        }
      }
    }
    predict(
      output,
      reference,
      x,
      y,
      physical,
      blockSize: blockSize,
      noRound: noRound,
      average: average,
      truncateAverage: average,
      bounds: bounds,
      lumaReferences: lumaReferences,
    );
  }
}

void _writeH263ReducedBlock(
  Uint8List plane,
  int offset,
  int stride,
  Int16List samples,
  bool intra,
) {
  // Q.6 expands only within this block. The August 2005 implementors' guide
  // specifies arithmetic shifts for rounding signed residuals.
  for (var y = 0; y < 16; y++) {
    final top = math.max(0, (y - 1) >> 1) * 8;
    final bottom = math.min(7, (y + 1) >> 1) * 8;
    final bottomWeight = y.isOdd ? 1 : 3;
    final topWeight = 4 - bottomWeight;
    for (var x = 0; x < 16; x++) {
      final left = math.max(0, (x - 1) >> 1);
      final right = math.min(7, (x + 1) >> 1);
      final rightWeight = x.isOdd ? 1 : 3;
      final leftWeight = 4 - rightWeight;
      final upper =
          samples[top + left] * leftWeight + samples[top + right] * rightWeight;
      final lower =
          samples[bottom + left] * leftWeight +
          samples[bottom + right] * rightWeight;
      final residual = (upper * topWeight + lower * bottomWeight + 8) >> 4;
      final index = offset + y * stride + x;
      plane[index] = ((intra ? 0 : plane[index]) + residual).clamp(0, 255);
    }
  }
}

void _filterH263Reduced(
  H263Picture picture,
  Uint8List coded,
  Uint16List? slices, {
  required bool deblock,
}) {
  final macroblockColumns = picture.columns >> 1;
  for (var p = 0; p < 3; p++) {
    final plane = picture.planes[p];
    final luma = p == 0;
    final columns = luma ? picture.columns : macroblockColumns;
    final rows = luma ? picture.rows : picture.rows >> 1;
    final sub = luma ? 1 : 0;
    final stride = columns * 16;
    // Finish all horizontal edges before filtering the vertical edges.
    for (final vertical in [false, true]) {
      final along = vertical ? stride : 1, across = vertical ? 1 : stride;
      for (var y = vertical ? 0 : 1; y < rows; y++) {
        for (var x = vertical ? 1 : 0; x < columns; x++) {
          final a = (y >> sub) * macroblockColumns + (x >> sub);
          final b =
              ((y - (vertical ? 0 : 1)) >> sub) * macroblockColumns +
              ((x - (vertical ? 1 : 0)) >> sub);
          if ((coded[a] | coded[b]) == 0 ||
              (slices != null && slices[a] != slices[b])) {
            continue;
          }
          var center = 16 * (y * stride + x);
          if (deblock) {
            _filterH263Edge(plane, center, across, along, null, length: 16);
          } else {
            for (var i = 0; i < 16; i++, center += along) {
              final left = plane[center - across], right = plane[center];
              plane[center - across] = (3 * left + right + 2) >> 2;
              plane[center] = (left + 3 * right + 2) >> 2;
            }
          }
        }
      }
    }
  }
}
