part of 'decoder.dart';

H263Picture _h263PredictionReference(
  H263Picture reference,
  H263Header header,
  bool roundingType,
) {
  final format = header.format;
  if (header.resampling == null && _h263Matches(reference, format)) {
    return _h263AlignReference(reference, reduced: header.reduced);
  }
  if (format.independentSegments) {
    throw const FormatException(
      'H.263+ independent reference picture size changed',
    );
  }
  if (!header.extended) {
    throw const FormatException('H.263 reference picture size changed');
  }
  final warp = header.resampling ?? h263ImplicitResampling;
  final output = H263Picture._(format);
  final logWidth = (format.width - 1).bitLength;
  final virtualWidth = 1 << logWidth;
  final virtualHeight = 1 << (format.height - 1).bitLength;
  final x = _h263WarpCorners(
    [for (final vector in warp.parameters) vector.x],
    format,
    virtualWidth,
    virtualHeight,
    2 * (reference.width - format.width),
    0,
  );
  final y = _h263WarpCorners(
    [for (final vector in warp.parameters) vector.y],
    format,
    virtualWidth,
    virtualHeight,
    0,
    2 * (reference.height - format.height),
  );
  final fill = warp.fill;
  final fills = [fill?.y, fill?.cb, fill?.cr];
  for (var plane = 0; plane < 3; plane++) {
    _h263WarpPlane(
      reference,
      output,
      plane,
      x,
      y,
      logWidth: logWidth,
      virtualHeight: virtualHeight,
      precisionBits: warp.precisionBits,
      fill: fills[plane],
      roundingType: roundingType,
    );
  }
  return _h263AlignReference(output, reduced: header.reduced);
}

typedef _H263WarpCorners = ({int lt, int rt, int lb, int rb});

_H263WarpCorners _h263WarpCorners(
  List<int> parameters,
  H263Format format,
  int virtualWidth,
  int virtualHeight,
  int sizeX,
  int sizeY,
) {
  // Annex P.3 extrapolates the four corners to a power-of-two grid in
  // units of 1/32 of a luma sample. Round after each full extrapolation.
  final origin = parameters[0] * 16;
  final horizontal = (parameters[1] + sizeX) * 16;
  final vertical = (parameters[2] + sizeY) * 16;
  final cross = parameters[3] * 16;
  final width = format.width, height = format.height;
  return (
    lt: origin,
    rt: _h263RoundAway(origin * width + horizontal * virtualWidth, width),
    lb: _h263RoundAway(origin * height + vertical * virtualHeight, height),
    rb: _h263RoundAway(
      origin * width * height +
          horizontal * virtualWidth * height +
          vertical * virtualHeight * width +
          cross * virtualWidth * virtualHeight,
      width * height,
    ),
  );
}

int _h263RoundAway(int value, int divisor) =>
    value.sign * ((value.abs() + divisor ~/ 2) ~/ divisor);

void _h263WarpPlane(
  H263Picture reference,
  H263Picture output,
  int plane,
  _H263WarpCorners x,
  _H263WarpCorners y, {
  required int logWidth,
  required int virtualHeight,
  required int precisionBits,
  required int? fill,
  required bool roundingType,
}) {
  final subsampling = plane == 0 ? 0 : 1;
  final source = reference.planes[plane], target = output.planes[plane];
  final maxX = (reference.width >> subsampling) - 1;
  final maxY = (reference.height >> subsampling) - 1;
  final sourceStride = reference.stride >> subsampling;
  final targetStride = output.stride >> subsampling;
  final width = output.width >> subsampling;
  final height = output.height >> subsampling;
  final spanX = 1 << (logWidth + 1 - subsampling);
  final spanY = virtualHeight << (1 - subsampling);
  final gridShift = logWidth + 6 - precisionBits;
  final halfGrid = 1 << (gridShift - 1);
  final pixelStep = 1 << (logWidth + 6);
  final phases = 1 << precisionBits;
  final sampleShift = 2 * precisionBits;
  // Annex P adds the RTYPE bit to the resampling bias.
  final bias = (1 << (sampleShift - 1)) - 1 + (roundingType ? 1 : 0);

  int sample(int column, int row) {
    if (column >= 0 && column <= maxX && row >= 0 && row <= maxY) {
      return source[row * sourceStride + column];
    }
    return fill ??
        source[row.clamp(0, maxY) * sourceStride + column.clamp(0, maxX)];
  }

  for (var row = 0; row < height; row++) {
    final bottom = 2 * row + 1, top = spanY - bottom;
    final leftX = _h263RoundAway(top * x.lt + bottom * x.lb, spanY);
    final rightX = _h263RoundAway(top * x.rt + bottom * x.rb, spanY);
    final leftY = _h263RoundAway(top * y.lt + bottom * y.lb, spanY);
    final rightY = _h263RoundAway(top * y.rt + bottom * y.rb, spanY);
    final dx = rightX - leftX, dy = rightY - leftY;
    var mappedX = leftX * spanX + dx + halfGrid;
    var mappedY = row * pixelStep + leftY * spanX + dy + halfGrid;
    final strideX = pixelStep + 2 * dx, strideY = 2 * dy;
    final start = row * targetStride;
    for (var column = 0; column < width; column++) {
      final ir = mappedX >> gridShift, jr = mappedY >> gridShift;
      final ix = ir >> precisionBits, iy = jr >> precisionBits;
      final fx = ir & (phases - 1), fy = jr & (phases - 1);
      final upper = (phases - fx) * sample(ix, iy) + fx * sample(ix + 1, iy);
      final lower =
          (phases - fx) * sample(ix, iy + 1) + fx * sample(ix + 1, iy + 1);
      target[start + column] =
          ((phases - fy) * upper + fy * lower + bias) >> sampleShift;
      mappedX += strideX;
      mappedY += strideY;
    }
    target.fillRange(
      start + width,
      start + targetStride,
      fill ?? target[start + width - 1],
    );
  }
  final end = height * targetStride;
  if (fill != null) {
    target.fillRange(end, target.length, fill);
  } else {
    for (var start = end; start < target.length; start += targetStride) {
      target.setRange(start, start + targetStride, target, end - targetStride);
    }
  }
}
