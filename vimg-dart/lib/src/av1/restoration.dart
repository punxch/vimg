part of 'picture_decoder.dart';

// AV1 §7.17.3 specifies two radius/strength pairs for each SGR preset.
const _sgrParameters = [
  (2, 12, 1, 4),
  (2, 15, 1, 6),
  (2, 18, 1, 8),
  (2, 21, 1, 9),
  (2, 24, 1, 10),
  (2, 29, 1, 11),
  (2, 36, 1, 12),
  (2, 45, 1, 13),
  (2, 56, 1, 14),
  (2, 68, 1, 15),
  (0, 0, 1, 5),
  (0, 0, 1, 8),
  (0, 0, 1, 11),
  (0, 0, 1, 14),
  (2, 30, 0, 0),
  (2, 75, 0, 0),
];

sealed class _RestorationUnit {
  const _RestorationUnit();
}

final class _WienerUnit extends _RestorationUnit {
  _WienerUnit(List<int> vertical, List<int> horizontal)
    : vertical = _taps(vertical),
      horizontal = _taps(horizontal);

  final List<int> vertical, horizontal;

  static List<int> _taps(List<int> coefficients) {
    final [a, b, c] = coefficients;
    return [a, b, c, 128 - 2 * (a + b + c), c, b, a];
  }
}

final class _SgrUnit extends _RestorationUnit {
  const _SgrUnit(this.index, this.weight0, this.weight1);

  final int index, weight0, weight1;
}

/// Frame-owned restoration grid. A short final unit is folded into its
/// neighbor. Vertical filter stripes start eight luma rows before the
/// corresponding 64-row boundary.
final class _RestorationPlane {
  _RestorationPlane(
    this.type,
    this.unitSize,
    this.subX,
    this.subY,
    this.width,
    this.height,
  );

  final Av1RestorationType type;
  final int unitSize, subX, subY, width, height;
  late final columns = math.max(1, (width + unitSize ~/ 2) ~/ unitSize);
  late final rows = math.max(1, (height + unitSize ~/ 2) ~/ unitSize);
  late final units = List<_RestorationUnit?>.filled(columns * rows, null);
  late final stripeHeight = 64 >> subY;
  late final stripeOffset = 8 >> subY;
  Uint16List? boundaries;

  void saveBoundaries(Av1Plane plane, _SuperresPlane? upscaler, int depth) {
    if (units.every((unit) => unit == null)) return;
    final count = (height + stripeOffset - 1) ~/ stripeHeight;
    final saved = boundaries = Uint16List(count * 4 * width);
    for (var stripe = 1; stripe <= count; stripe++) {
      final edge = stripe * stripeHeight - stripeOffset;
      for (var row = 0; row < 4; row++) {
        final source = (edge + row - 2).clamp(0, height - 1) * plane.stride;
        final target = ((stripe - 1) * 4 + row) * width;
        if (upscaler == null) {
          saved.setRange(target, target + width, plane.samples, source);
        } else {
          upscaler.upscaleRow(plane.samples, source, saved, target, depth);
        }
      }
    }
  }

  void apply(Av1Plane plane, int depth) {
    final saved = boundaries;
    if (saved == null) return;
    final cdef = Uint16List(stripeHeight * width);
    for (var stripe = 0; ; stripe++) {
      final start = stripe * stripeHeight - stripeOffset;
      final top = math.max(0, start);
      if (top >= height) break;
      final bottom = math.min(height, start + stripeHeight);
      final row = math.min(rows - 1, stripe * stripeHeight ~/ unitSize);
      final unitOffset = row * columns;
      for (var y = top; y < bottom; y++) {
        final offset = (y - top) * width;
        cdef.setRange(offset, offset + width, plane.samples, y * plane.stride);
      }
      final source = _RestorationStripe(
        width,
        height,
        start,
        top,
        start + stripeHeight,
        stripe,
        cdef,
        saved,
      );
      for (var col = 0; col < columns; col++) {
        final x = col * unitSize;
        final w = col == columns - 1 ? width - x : unitSize;
        final unit = units[unitOffset + col];
        switch (unit) {
          case _WienerUnit():
            _restoreWiener(plane, source, unit, x, top, w, bottom - top, depth);
          case _SgrUnit():
            _restoreSgr(plane, source, unit, x, top, w, bottom - top, depth);
          case null:
            break;
        }
      }
    }
    boundaries = null;
  }
}

final class _RestorationFrame {
  _RestorationFrame(Av1CodedFrame frame, List<Av1Plane> picture)
    : denominator = frame.header.size.superresDenominator,
      planes = [
        for (final (i, plane) in picture.indexed) _plane(frame, plane, i),
      ];

  final int denominator;
  final List<_RestorationPlane?> planes;

  static _RestorationPlane? _plane(
    Av1CodedFrame frame,
    Av1Plane plane,
    int index,
  ) {
    final config = frame.header.parameters.restoration;
    if (config == null || config.types[index] == Av1RestorationType.none) {
      return null;
    }
    final color = frame.sequence.color;
    final subX = index == 0 ? 0 : color.subsamplingX;
    return _RestorationPlane(
      config.types[index],
      index == 0 ? config.lumaUnit : config.chromaUnit,
      subX,
      index == 0 ? 0 : color.subsamplingY,
      (frame.header.size.upscaledWidth + subX) >> subX,
      plane.height,
    );
  }

  void saveBoundaries(
    List<Av1Plane> picture,
    List<_SuperresPlane?>? upscalers,
    int depth,
  ) {
    for (final (i, plane) in planes.indexed) {
      plane?.saveBoundaries(picture[i], upscalers?[i], depth);
    }
  }

  void apply(List<Av1Plane> picture, int depth) {
    for (final (i, plane) in planes.indexed) {
      plane?.apply(picture[i], depth);
    }
  }
}

/// Restoration predictors reset at the start of every tile, while the
/// probabilities follow the tile's normal entropy context.
final class _RestorationTile {
  _RestorationTile(this.frame, this.reader, this.context);

  final _RestorationFrame frame;
  final RangeDecoder reader;
  final Av1EntropyContext context;
  final _wiener = [
    for (var plane = 0; plane < 3; plane++)
      [
        for (var pass = 0; pass < 2; pass++) [plane == 0 ? 3 : 0, -7, 15],
      ],
  ];
  final _sgr = [
    for (var plane = 0; plane < 3; plane++) [-32, 31],
  ];

  void readSuperblock(int x, int y, int size) {
    for (final (i, plane) in frame.planes.indexed) {
      if (plane == null) continue;
      final step = plane.unitSize;
      final xStep = (4 >> plane.subX) * frame.denominator;
      final xUnit = step * 8;
      final yShift = 2 - plane.subY;
      final firstX = (x * xStep + xUnit - 1) ~/ xUnit;
      final lastX = math.min(
        plane.columns,
        ((x + size) * xStep + xUnit - 1) ~/ xUnit,
      );
      final firstY = ((y << yShift) + step - 1) ~/ step;
      final lastY = math.min(
        plane.rows,
        (((y + size) << yShift) + step - 1) ~/ step,
      );
      for (var row = firstY; row < lastY; row++) {
        for (var col = firstX; col < lastX; col++) {
          plane.units[row * plane.columns + col] = _readUnit(i, plane.type);
        }
      }
    }
  }

  _RestorationUnit? _readUnit(int plane, Av1RestorationType type) {
    final symbol = switch (type) {
      Av1RestorationType.switchable => reader.adaptive(
        context.cdf(type, const [9413, 22581]),
      ),
      Av1RestorationType.wiener => reader.adaptive(
        context.cdf(type, const [11570]),
      ),
      Av1RestorationType.sgrproj =>
        2 * reader.adaptive(context.cdf(type, const [16855])),
      Av1RestorationType.none => 0,
    };
    if (symbol == 0) return null;
    if (symbol == 1) {
      final taps = _wiener[plane];
      const minima = [-5, -23, -17];
      for (final pass in taps) {
        for (var i = plane == 0 ? 0 : 1; i < 3; i++) {
          pass[i] = _subexp(pass[i], minima[i], i + 1);
        }
      }
      return _WienerUnit(taps[0], taps[1]);
    }
    final index = reader.literal(4);
    final (r0, _, r1, _) = _sgrParameters[index];
    final weights = _sgr[plane];
    weights[0] = r0 == 0 ? 0 : _subexp(weights[0], -96, 4);
    weights[1] = r1 == 0 ? 95 : _subexp(weights[1], -32, 4);
    return _SgrUnit(index, weights[0], weights[1]);
  }

  int _subexp(int reference, int minimum, int k) {
    final count = 8 << k;
    var offset = 0;
    int value;
    for (var i = 0; ; i++) {
      final bits = i == 0 ? k : k + i - 1;
      final span = 1 << bits;
      if (count <= offset + 3 * span) {
        value = offset + reader.uniform(count - offset);
        break;
      }
      if (reader.literal(1) == 0) {
        value = offset + reader.literal(bits);
        break;
      }
      offset += span;
    }
    final center = reference - minimum;
    int recenter(int r) {
      if (value > 2 * r) return value;
      return value.isOdd ? r - ((value + 1) >> 1) : r + (value >> 1);
    }

    return minimum +
        (2 * center <= count
            ? recenter(center)
            : count - 1 - recenter(count - 1 - center));
  }
}

/// Unmodified CDEF rows inside a stripe and deblocked rows at its edges.
final class _RestorationStripe {
  const _RestorationStripe(
    this.width,
    this.height,
    this.start,
    this.top,
    this.end,
    this.index,
    this.cdef,
    this.boundaries,
  );

  final int width, height, start, top, end, index;
  final Uint16List cdef, boundaries;

  int sample(int x, int y) {
    x = x.clamp(0, width - 1);
    y = y.clamp(0, height - 1);
    if (y < start) {
      final row = (index - 1) * 4 + math.max<int>(0, y - start + 2);
      return boundaries[row * width + x];
    }
    if (y >= end) {
      final row = index * 4 + 2 + math.min<int>(1, y - end);
      return boundaries[row * width + x];
    }
    return cdef[(y - top) * width + x];
  }
}

int _lrRound(int value, int bits) => (value + ((1 << bits) >> 1)) >> bits;

void _restoreWiener(
  Av1Plane plane,
  _RestorationStripe source,
  _WienerUnit unit,
  int x,
  int y,
  int width,
  int height,
  int depth,
) {
  final round0 = depth == 12 ? 5 : 3;
  final offset = 1 << (depth + 6 - round0);
  final limit = (1 << (depth + 8 - round0)) - 1 - offset;
  final intermediate = Int16List(width * (height + 6));
  for (var row = 0; row < height + 6; row++) {
    for (var col = 0; col < width; col++) {
      var sum = 0;
      for (var tap = 0; tap < 7; tap++) {
        sum +=
            unit.horizontal[tap] *
            source.sample(x + col + tap - 3, y + row - 3);
      }
      intermediate[row * width + col] = _lrRound(
        sum,
        round0,
      ).clamp(-offset, limit);
    }
  }
  final maximum = (1 << depth) - 1;
  for (var row = 0; row < height; row++) {
    final dst = (y + row) * plane.stride + x;
    for (var col = 0; col < width; col++) {
      var sum = 0;
      for (var tap = 0; tap < 7; tap++) {
        sum += unit.vertical[tap] * intermediate[(row + tap) * width + col];
      }
      plane.samples[dst + col] = _lrRound(sum, 14 - round0).clamp(0, maximum);
    }
  }
}

void _restoreSgr(
  Av1Plane plane,
  _RestorationStripe source,
  _SgrUnit unit,
  int x,
  int y,
  int width,
  int height,
  int depth,
) {
  final (r0, eps0, r1, eps1) = _sgrParameters[unit.index];
  final first = r0 == 0
      ? null
      : _sgrCoefficients(source, x, y, width, height, depth, r0, eps0);
  final second = r1 == 0
      ? null
      : _sgrCoefficients(source, x, y, width, height, depth, r1, eps1);
  final weight2 = 128 - unit.weight0 - unit.weight1;
  final maximum = (1 << depth) - 1;
  for (var row = 0; row < height; row++) {
    final dst = (y + row) * plane.stride + x;
    final src = (y + row - source.top) * source.width + x;
    for (var col = 0; col < width; col++) {
      final sample = source.cdef[src + col];
      final base = sample << 4;
      final filtered0 = first == null ? base : first.filter(col, row, sample);
      final filtered1 = second == null ? base : second.filter(col, row, sample);
      final value =
          unit.weight1 * base + unit.weight0 * filtered0 + weight2 * filtered1;
      plane.samples[dst + col] = _lrRound(value, 11).clamp(0, maximum);
    }
  }
}

final class _SgrCoefficients {
  _SgrCoefficients(this.stride, int height, this.radius)
    : a = Int16List(stride * (height + 2)),
      b = Int32List(stride * (height + 2));

  final int stride, radius;
  final Int16List a;
  final Int32List b;

  int filter(int x, int y, int sample) {
    var gain = 0, bias = 0;
    final sparse = radius == 2;
    for (var dy = -1; dy <= 1; dy++) {
      if (sparse && (y + dy).isEven) continue;
      final offset = (y + dy + 1) * stride + x + 1;
      for (var dx = -1; dx <= 1; dx++) {
        final weight = sparse
            ? (dx == 0 ? 6 : 5)
            : (dx == 0 || dy == 0 ? 4 : 3);
        gain += weight * a[offset + dx];
        bias += weight * b[offset + dx];
      }
    }
    return _lrRound(gain * sample + bias, sparse && y.isOdd ? 8 : 9);
  }
}

_SgrCoefficients _sgrCoefficients(
  _RestorationStripe source,
  int x,
  int y,
  int width,
  int height,
  int depth,
  int radius,
  int epsilon,
) {
  final side = 2 * radius + 1;
  final count = side * side;
  final denominator = count * count * epsilon;
  final scale = ((1 << 20) + denominator ~/ 2) ~/ denominator;
  final reciprocal = ((1 << 12) + count ~/ 2) ~/ count;
  final shift = depth - 8;
  final coefficients = _SgrCoefficients(width + 2, height, radius);

  // Summed-area tables cover the output rectangle and the full filter halo.
  final stride = width + side + 2;
  final sampleRows = height + side + 1;
  final sums = Int32List(stride * (sampleRows + 1));
  final squares = Int64List(sums.length);
  for (var row = 0; row < sampleRows; row++) {
    var sum = 0, square = 0;
    final offset = (row + 1) * stride;
    for (var col = 0; col < stride - 1; col++) {
      final value = source.sample(x + col - radius - 1, y + row - radius - 1);
      sum += value;
      square += value * value;
      sums[offset + col + 1] = sums[offset - stride + col + 1] + sum;
      squares[offset + col + 1] = squares[offset - stride + col + 1] + square;
    }
  }
  for (var row = 0; row < height + 2; row += radius == 2 ? 2 : 1) {
    for (var col = 0; col < width + 2; col++) {
      final top = row * stride + col, bottom = top + side * stride;
      final sum =
          sums[bottom + side] - sums[bottom] - sums[top + side] + sums[top];
      final square =
          squares[bottom + side] -
          squares[bottom] -
          squares[top + side] +
          squares[top];
      final scaled = _lrRound(sum, shift);
      final variance = math.max(
        0,
        _lrRound(square, 2 * shift) * count - scaled * scaled,
      );
      final z = _lrRound(variance * scale, 20);
      final gain = z == 0
          ? 1
          : z >= 255
          ? 256
          : ((z << 8) + z ~/ 2) ~/ (z + 1);
      final index = row * coefficients.stride + col;
      coefficients.a[index] = gain;
      coefficients.b[index] = _lrRound((256 - gain) * sum * reciprocal, 12);
    }
  }
  return coefficients;
}
