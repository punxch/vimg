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
  _H263WarpPlane makePlane(int plane, int stride, int height) => _H263WarpPlane(
    reference,
    format,
    plane,
    stride,
    height,
    x,
    y,
    logWidth: logWidth,
    virtualHeight: virtualHeight,
    precisionBits: warp.precisionBits,
    fill: fills[plane],
    roundingType: roundingType,
  );
  if (reference._subPictures != null) {
    // An unused source tile does not invalidate unrelated warped pixels.
    // Evaluate only the pixels subsequently requested by motion prediction.
    return H263Picture._reference(format, makePlane, reduced: header.reduced);
  }
  final output = H263Picture._(format);
  for (var plane = 0; plane < 3; plane++) {
    makePlane(
      plane,
      output.stride,
      output.rows * 16,
    ).write(output.planes[plane]);
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

typedef _H263WarpRow = ({int x, int y, int stepX, int stepY});

final class _H263WarpPlane extends _H263ReadOnlyPlane {
  _H263WarpPlane(
    H263Picture reference,
    H263Format format,
    int plane,
    int stride,
    int height,
    this._x,
    this._y, {
    required int logWidth,
    required int virtualHeight,
    required int precisionBits,
    required int? fill,
    required bool roundingType,
  }) : _source = reference._referencePlane(plane),
       _maxX = (reference.width >> (plane == 0 ? 0 : 1)) - 1,
       _maxY = (reference.height >> (plane == 0 ? 0 : 1)) - 1,
       _sourceStride = reference.stride >> (plane == 0 ? 0 : 1),
       _stride = stride >> (plane == 0 ? 0 : 1),
       _paddedHeight = height >> (plane == 0 ? 0 : 1),
       _width = format.width >> (plane == 0 ? 0 : 1),
       _height = format.height >> (plane == 0 ? 0 : 1),
       _spanX = 1 << (logWidth + (plane == 0 ? 1 : 0)),
       _spanY = virtualHeight << (plane == 0 ? 1 : 0),
       _gridShift = logWidth + 6 - precisionBits,
       _pixelStep = 1 << (logWidth + 6),
       _precisionBits = precisionBits,
       _fill = fill,
       // Annex P adds the RTYPE bit to the resampling bias.
       _bias = (1 << (2 * precisionBits - 1)) - 1 + (roundingType ? 1 : 0);

  final List<int> _source;
  final _H263WarpCorners _x, _y;
  final int _maxX, _maxY, _sourceStride, _stride, _paddedHeight;
  final int _width, _height, _spanX, _spanY, _gridShift, _pixelStep;
  final int _precisionBits, _bias;
  final int? _fill;
  late final _phases = 1 << _precisionBits;
  late final _rows = List<_H263WarpRow?>.filled(_height, null);

  _H263WarpRow _row(int row) {
    final bottom = 2 * row + 1, top = _spanY - bottom;
    final leftX = _h263RoundAway(top * _x.lt + bottom * _x.lb, _spanY);
    final rightX = _h263RoundAway(top * _x.rt + bottom * _x.rb, _spanY);
    final leftY = _h263RoundAway(top * _y.lt + bottom * _y.lb, _spanY);
    final rightY = _h263RoundAway(top * _y.rt + bottom * _y.rb, _spanY);
    final dx = rightX - leftX, dy = rightY - leftY;
    final halfGrid = 1 << (_gridShift - 1);
    return (
      x: leftX * _spanX + dx + halfGrid,
      y: row * _pixelStep + leftY * _spanX + dy + halfGrid,
      stepX: _pixelStep + 2 * dx,
      stepY: 2 * dy,
    );
  }

  int _sourcePixel(int column, int row) {
    if (column >= 0 && column <= _maxX && row >= 0 && row <= _maxY) {
      return _source[row * _sourceStride + column];
    }
    return _fill ??
        _source[row.clamp(0, _maxY) * _sourceStride + column.clamp(0, _maxX)];
  }

  int _evaluate(int mappedX, int mappedY) {
    final ir = mappedX >> _gridShift, jr = mappedY >> _gridShift;
    final ix = ir >> _precisionBits, iy = jr >> _precisionBits;
    final fx = ir & (_phases - 1), fy = jr & (_phases - 1);
    int horizontal(int row) {
      final left = (_phases - fx) * _sourcePixel(ix, row);
      return fx == 0 ? left : left + fx * _sourcePixel(ix + 1, row);
    }

    final upper = (_phases - fy) * horizontal(iy);
    final lower = fy == 0 ? 0 : fy * horizontal(iy + 1);
    return (upper + lower + _bias) >> (2 * _precisionBits);
  }

  @override
  int get length => _stride * _paddedHeight;

  @override
  int operator [](int index) {
    RangeError.checkValidIndex(index, this);
    final x = index % _stride, y = index ~/ _stride;
    if (_fill case final fill? when x >= _width || y >= _height) return fill;
    final column = math.min(x, _width - 1), row = math.min(y, _height - 1);
    final mapping = _rows[row] ??= _row(row);
    return _evaluate(
      mapping.x + mapping.stepX * column,
      mapping.y + mapping.stepY * column,
    );
  }

  void write(Uint8List target) {
    for (var row = 0; row < _height; row++) {
      final (:x, :y, :stepX, :stepY) = _row(row);
      var mappedX = x, mappedY = y;
      final start = row * _stride;
      for (var column = 0; column < _width; column++) {
        target[start + column] = _evaluate(mappedX, mappedY);
        mappedX += stepX;
        mappedY += stepY;
      }
      target.fillRange(
        start + _width,
        start + _stride,
        _fill ?? target[start + _width - 1],
      );
    }
    final end = _height * _stride;
    if (_fill case final fill?) {
      target.fillRange(end, target.length, fill);
    } else {
      for (var start = end; start < target.length; start += _stride) {
        target.setRange(start, start + _stride, target, end - _stride);
      }
    }
  }
}
