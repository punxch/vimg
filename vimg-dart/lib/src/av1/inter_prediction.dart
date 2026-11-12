import 'dart:math' as math;
import 'dart:typed_data';

import 'inter_prediction_tables.dart';
import 'transform.dart';

typedef Av1Mv = ({int x, int y});
const av1ZeroMv = (x: 0, y: 0);

enum Av1Compound { average, distance, wedge, difference }

/// The AV1 inter predictor retains the intermediate precision used by
/// compound blends and clips only when writing the destination samples.
final class Av1InterPredictor {
  final first = Int32List(128 * 128);
  final second = Int32List(128 * 128);
  final mask = Uint8List(128 * 128);
  final _intermediate = Int32List(128 * (256 + 8));
  final _columns = Int32List(128);
  final _phases = Uint8List(128);

  /// §7.11.3.2–4. Coordinates and width/height are in the current plane.
  /// Scale ratios use the luma dimensions, including for chroma.
  void convolve(
    Int32List output,
    Uint16List source, {
    required int stride,
    required int referenceWidth,
    required int referenceHeight,
    required int frameWidth,
    required int frameHeight,
    required int x,
    required int y,
    required int width,
    required int height,
    required int sx,
    required int sy,
    required Av1Mv mv,
    required int filterX,
    required int filterY,
    required int depth,
    required bool compound,
  }) {
    final (startX, stepX) = _scaledAxis(
      x,
      mv.x,
      sx,
      frameWidth,
      referenceWidth,
    );
    final (startY, stepY) = _scaledAxis(
      y,
      mv.y,
      sy,
      frameHeight,
      referenceHeight,
    );
    final lastX = ((referenceWidth + sx) >> sx) - 1;
    final lastY = ((referenceHeight + sy) >> sy) - 1;
    final round0 = depth == 12 ? 5 : 3;
    final round1 = compound ? 7 : 14 - round0;

    if (stepX == 1024 && stepY == 1024 && ((startX | startY) & 0x3c0) == 0) {
      final baseX = startX >> 10, baseY = startY >> 10;
      final precision = 14 - round0 - round1;
      for (var j = 0, i = 0; j < height; j++) {
        final row = (baseY + j).clamp(0, lastY) * stride;
        for (var k = 0; k < width; k++) {
          output[i++] = source[row + (baseX + k).clamp(0, lastX)] << precision;
        }
      }
      return;
    }

    final xFilters = av1SubpelFilters[_filterIndex(filterX, width)];
    final yFilters = av1SubpelFilters[_filterIndex(filterY, height)];
    for (var c = 0, p = startX; c < width; c++, p += stepX) {
      _columns[c] = p >> 10;
      _phases[c] = (p >> 6) & 15;
    }
    final rows = (((height - 1) * stepY + 1023) >> 10) + 8;
    final baseY = (startY >> 10) - 3;
    for (var j = 0, out = 0; j < rows; j++) {
      final row = (baseY + j).clamp(0, lastY) * stride;
      for (var k = 0; k < width; k++) {
        final c = _columns[k], phase = _phases[k];
        if (phase == 0) {
          _intermediate[out++] =
              source[row + c.clamp(0, lastX)] << (7 - round0);
        } else {
          final taps = xFilters[phase];
          var sum = 0;
          for (var i = 0; i < 8; i++) {
            sum += taps[i] * source[row + (c + i - 3).clamp(0, lastX)];
          }
          _intermediate[out++] = av1Round(sum, round0);
        }
      }
    }
    var offset = startY & 1023;
    for (var j = 0, out = 0; j < height; j++, offset += stepY) {
      final row = (offset >> 10) * width;
      final phase = (offset >> 6) & 15;
      final taps = yFilters[phase];
      for (var k = 0; k < width; k++) {
        var sum = 0;
        for (var i = 0; i < 8; i++) {
          sum += taps[i] * _intermediate[row + i * width + k];
        }
        output[out++] = av1Round(sum, round1);
      }
    }
  }

  void makeDifferenceMask(int count, int depth, bool invert) {
    final shift = depth - 8 + _postRound(depth);
    for (var i = 0; i < count; i++) {
      final difference = (first[i] - second[i]).abs();
      final weight = (38 + (av1Round(difference, shift) >> 4)).clamp(0, 64);
      mask[i] = invert ? 64 - weight : weight;
    }
  }

  void makeWedgeMask(int width, int height, int index, bool invert) {
    final shape = height > width
        ? 0
        : height < width
        ? 1
        : 2;
    final code = av1WedgeCodebook[shape][index];
    final offsetX = 32 - ((code[1] * width) >> 3);
    final offsetY = 32 - ((code[2] * height) >> 3);
    final direction = code[0];
    var sum = 0;
    for (var c = 0; c < width; c++) {
      sum += _wedge(direction, offsetX + c, offsetY);
    }
    for (var r = 1; r < height; r++) {
      sum += _wedge(direction, offsetX, offsetY + r);
    }
    final length = width + height - 1;
    final flip = invert != ((sum + (length >> 1)) ~/ length < 32);
    for (var r = 0, i = 0; r < height; r++) {
      for (var c = 0; c < width; c++) {
        final value = _wedge(direction, offsetX + c, offsetY + r);
        mask[i++] = flip ? 64 - value : value;
      }
    }
  }

  void write(
    Uint16List output, {
    required int stride,
    required int x,
    required int y,
    required int width,
    required int height,
    required int depth,
    Av1Compound? compound,
    int firstWeight = 8,
    int sx = 0,
    int sy = 0,
  }) {
    final maximum = (1 << depth) - 1;
    final post = _postRound(depth);
    final maskStride = width << sx;
    for (var r = 0, i = 0; r < height; r++) {
      final row = (y + r) * stride + x;
      for (var c = 0; c < width; c++, i++) {
        final a = first[i], b = second[i];
        final int value;
        switch (compound) {
          case null:
            value = a;
          case Av1Compound.average:
            value = av1Round(a + b, 1 + post);
          case Av1Compound.distance:
            value = av1Round(
              firstWeight * a + (16 - firstWeight) * b,
              4 + post,
            );
          case Av1Compound.wedge || Av1Compound.difference:
            final w = maskAt(c, r, maskStride, sx, sy);
            value = av1Round(w * a + (64 - w) * b, 6 + post);
        }
        output[row + c] = value.clamp(0, maximum);
      }
    }
  }

  int maskAt(int x, int y, int stride, int sx, int sy) {
    final start = (y << sy) * stride + (x << sx);
    var sum = mask[start];
    if (sx != 0) sum += mask[start + 1];
    if (sy != 0) {
      sum += mask[start + stride];
      if (sx != 0) sum += mask[start + stride + 1];
    }
    return av1Round(sum, sx + sy);
  }
}

int _postRound(int depth) => depth == 12 ? 2 : 4;

int _filterIndex(int kind, int size) =>
    size <= 4 && kind < 3 ? (kind == 1 ? 5 : 4) : kind;

(int, int) _scaledAxis(int origin, int mv, int sub, int frame, int ref) {
  final scale = ((ref << 14) + (frame >> 1)) ~/ frame;
  final center = (origin << 4) + ((2 * mv) >> sub) + 8;
  final adjusted = center * scale - (8 << 14);
  final rounded = adjusted.sign * av1Round(adjusted.abs(), 8);
  return (rounded + 32, av1Round(scale, 4));
}

int _oblique63(int x, int y) => y.isEven
    ? av1WedgeMasterObliqueEven[(x - 16 + (y >> 1)).clamp(0, 63)]
    : av1WedgeMasterObliqueOdd[(x - 15 + (y >> 1)).clamp(0, 63)];

int _wedge(int direction, int x, int y) => switch (direction) {
  0 => av1WedgeMasterVertical[y],
  1 => av1WedgeMasterVertical[x],
  2 => _oblique63(y, x),
  3 => _oblique63(x, y),
  4 => 64 - _oblique63(63 - x, y),
  _ => 64 - _oblique63(y, 63 - x),
};

int av1DistanceWeight(int distance0, int distance1) {
  final d0 = math.min(31, distance1.abs()), d1 = math.min(31, distance0.abs());
  final order = d0 <= d1 ? 1 : 0;
  const ratios = [(2, 3), (2, 5), (2, 7)];
  const weights = [9, 11, 12, 13];
  var ratio = 3;
  if (d0 != 0 && d1 != 0) {
    for (var i = 0; i < ratios.length; i++) {
      final (a, b) = ratios[i];
      if (order == 0 ? d0 * a < d1 * b : d0 * b > d1 * a) {
        ratio = i;
        break;
      }
    }
  }
  return order == 0 ? weights[ratio] : 16 - weights[ratio];
}
