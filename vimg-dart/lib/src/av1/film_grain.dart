part of 'picture_decoder.dart';

/// AV1 §7.18.3. Synthesize grain on display planes. The caller can retain
/// the unmodified reconstructed planes for inter prediction and redisplay.
Av1Picture applyAv1FilmGrain(Av1Picture picture, Av1FilmGrain? parameters) {
  if (parameters == null ||
      (parameters.luma.isEmpty &&
          parameters.cb.points.isEmpty &&
          parameters.cr.points.isEmpty &&
          !(parameters.chromaFromLuma && parameters.restrictedRange))) {
    return picture;
  }
  return _FilmGrainSynthesis(picture, parameters).apply();
}

final class _FilmGrainSynthesis {
  _FilmGrainSynthesis(this.picture, this.parameters);

  final Av1Picture picture;
  final Av1FilmGrain parameters;
  late final depthShift = picture.color.depth - 8;
  late final grainCenter = 128 << depthShift;
  late final sampleMax = (1 << picture.color.depth) - 1;

  Av1Picture apply() {
    final luma = picture.planes[0];
    final lumaTemplate = parameters.luma.isEmpty
        ? null
        : _generateTemplate(0, 0, parameters.seed, parameters.lumaCoefficients);
    final lumaScaling = _grainScaling(parameters.luma, depthShift);
    return Av1Picture(picture.color, [
      if (lumaTemplate == null)
        luma
      else
        _applyPlane(luma, lumaTemplate, lumaScaling),
      if (!picture.color.monochrome)
        for (final (i, chroma) in [parameters.cb, parameters.cr].indexed)
          if (parameters.chromaFromLuma || chroma.points.isNotEmpty)
            _applyPlane(
              picture.planes[i + 1],
              _generateTemplate(
                picture.color.subsamplingX,
                picture.color.subsamplingY,
                parameters.seed ^ (i == 0 ? 0xb524 : 0x49d8),
                chroma.coefficients,
                lumaTemplate,
              ),
              parameters.chromaFromLuma
                  ? lumaScaling
                  : _grainScaling(chroma.points, depthShift),
              chroma,
            )
          else
            picture.planes[i + 1],
    ]);
  }

  Int16List _generateTemplate(
    int subX,
    int subY,
    int seed,
    List<int> coefficients, [
    Int16List? luma,
  ]) {
    final width = subX == 0 ? 82 : 44;
    final height = subY == 0 ? 73 : 38;
    final random = _GrainRandom(seed);
    final shift = 4 - depthShift + parameters.grainShift;
    final samples = Int16List(width * height);
    for (var i = 0; i < samples.length; i++) {
      samples[i] = av1Round(_gaussianSequence[random.next(11)], shift);
    }
    final lag = parameters.lag;
    final offsets = [
      for (var y = -lag; y <= 0; y++)
        for (var x = -lag; x <= (y == 0 ? -1 : lag); x++) y * width + x,
    ];
    for (var y = 3; y < height; y++) {
      for (var x = 3; x < width - 3; x++) {
        final index = y * width + x;
        var sum = 0;
        for (var k = 0; k < offsets.length; k++) {
          sum += samples[index + offsets[k]] * coefficients[k];
        }
        if (luma != null) {
          final lx = ((x - 3) << subX) + 3;
          final ly = ((y - 3) << subY) + 3;
          var correlated = 0;
          for (var j = 0; j <= subY; j++) {
            for (var i = 0; i <= subX; i++) {
              correlated += luma[(ly + j) * 82 + lx + i];
            }
          }
          sum += av1Round(correlated, subX + subY) * coefficients.last;
        }
        samples[index] =
            (samples[index] + av1Round(sum, parameters.coefficientShift)).clamp(
              -grainCenter,
              grainCenter - 1,
            );
      }
    }
    return samples;
  }

  Av1Plane _applyPlane(
    Av1Plane source,
    Int16List grain,
    Uint8List scaling, [
    Av1GrainChroma? chroma,
  ]) {
    final sx = chroma == null ? 0 : picture.color.subsamplingX;
    final sy = chroma == null ? 0 : picture.color.subsamplingY;
    final width = source.width, height = source.height;
    final output = Av1Plane(width, height, width, height);
    final blockWidth = 32 >> sx, blockHeight = 32 >> sy;
    final overlapX = parameters.overlap ? 2 >> sx : 0;
    final overlapY = parameters.overlap ? 2 >> sy : 0;
    // Keep the last stripe's lower fringe for the next vertical blend.
    final stripeHeight = blockHeight + overlapY;
    var stripe = Int16List(width * stripeHeight);
    var previous = overlapY == 0 ? stripe : Int16List(stripe.length);
    final grainWidth = sx == 0 ? 82 : 44;
    final luma = picture.planes[0];
    final minValue = parameters.restrictedRange ? 16 << depthShift : 0;
    final maxValue = parameters.restrictedRange
        ? (chroma == null || picture.color.matrix == 0 ? 235 : 240) <<
              depthShift
        : sampleMax;

    for (var row = 0, top = 0; top < height; row++, top += blockHeight) {
      final seed =
          parameters.seed ^
          (((row * 37 + 178) & 255) << 8) ^
          ((row * 173 + 105) & 255);
      final random = _GrainRandom(seed);
      for (var left = 0; left < width; left += blockWidth) {
        final offset = random.next(8);
        final gx = 3 + ((3 + (offset >> 4)) << (1 - sx));
        final gy = 3 + ((3 + (offset & 15)) << (1 - sy));
        final columns = math.min(width - left, blockWidth + overlapX);
        for (var y = 0; y < stripeHeight; y++) {
          final index = y * width + left;
          final from = (gy + y) * grainWidth + gx;
          for (var x = 0; x < columns; x++) {
            final value = grain[from + x];
            stripe[index + x] = left != 0 && x < overlapX
                ? _overlap(stripe[index + x], value, sx, x)
                : value;
          }
        }
      }

      final rows = math.min(height - top, blockHeight);
      for (var y = 0; y < rows; y++) {
        final sourceRow = (top + y) * source.stride;
        final lumaRow = ((top + y) << sy) * luma.stride;
        final destinationRow = (top + y) * width;
        final blend = row != 0 && y < overlapY;
        for (var x = 0; x < width; x++) {
          final original = source.samples[sourceRow + x];
          var index = original;
          if (chroma != null) {
            final lx = x << sx;
            var average = luma.samples[lumaRow + lx];
            if (sx != 0 && lx + 1 < luma.width) {
              average = (average + luma.samples[lumaRow + lx + 1] + 1) >> 1;
            }
            index = parameters.chromaFromLuma
                ? average
                : (((average * chroma.lumaMultiplier +
                                  original * chroma.multiplier) >>
                              6) +
                          (chroma.offset << depthShift))
                      .clamp(0, sampleMax);
          }
          final noise = stripe[y * width + x];
          final blended = blend
              ? _overlap(previous[(blockHeight + y) * width + x], noise, sy, y)
              : noise;
          final delta = av1Round(
            blended * scaling[index],
            parameters.scalingShift,
          );
          output.samples[destinationRow + x] = (original + delta).clamp(
            minValue,
            maxValue,
          );
        }
      }
      (stripe, previous) = (previous, stripe);
    }
    return output;
  }

  int _overlap(int previous, int current, int subsampling, int position) {
    final (a, b) = subsampling != 0
        ? (23, 22)
        : position == 0
        ? (27, 17)
        : (17, 27);
    return av1Round(
      a * previous + b * current,
      5,
    ).clamp(-grainCenter, grainCenter - 1);
  }
}

final class _GrainRandom {
  _GrainRandom(this.state);

  int state;

  int next(int bits) {
    final bit = (state ^ (state >> 1) ^ (state >> 3) ^ (state >> 12)) & 1;
    state = (state >> 1) | (bit << 15);
    return state >> (16 - bits);
  }
}

/// Build the eight-bit piecewise curve, then interpolate between those
/// rounded samples at higher depths.
Uint8List _grainScaling(List<Av1GrainPoint> points, int shift) {
  final table = Uint8List(256);
  if (points.isNotEmpty) {
    table.fillRange(0, points.first.value, points.first.scaling);
    for (var i = 1; i < points.length; i++) {
      final from = points[i - 1], to = points[i];
      final span = to.value - from.value;
      final step =
          (to.scaling - from.scaling) * ((65536 + (span >> 1)) ~/ span);
      for (var x = 0; x < span; x++) {
        table[from.value + x] = from.scaling + av1Round(x * step, 16);
      }
    }
    table.fillRange(points.last.value, 256, points.last.scaling);
  }
  if (shift == 0) return table;
  final scale = 1 << shift;
  final output = Uint8List(256 * scale);
  for (var x = 0; x < 255; x++) {
    final start = table[x], delta = table[x + 1] - start;
    for (var sub = 0; sub < scale; sub++) {
      output[x * scale + sub] = start + av1Round(delta * sub, shift);
    }
  }
  output.fillRange(255 * scale, output.length, table[255]);
  return output;
}
