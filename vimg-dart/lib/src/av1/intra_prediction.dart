import 'dart:math' as math;
import 'dart:typed_data';

import 'intra_prediction_tables.dart';
import 'transform.dart';

enum Av1IntraMode {
  dc,
  vertical,
  horizontal,
  d45,
  d135,
  d113,
  d157,
  d203,
  d67,
  smooth,
  smoothVertical,
  smoothHorizontal,
  paeth,
  cfl;

  bool get directional => index >= vertical.index && index <= d67.index;
  bool get smoothEdge =>
      this == smooth || this == smoothVertical || this == smoothHorizontal;
}

const _angles = [0, 90, 180, 45, 135, 113, 157, 203, 67];

/// AV1 §7.11.2. The edge buffers reserve two cells for indices -2 and -1.
final class Av1IntraPredictor {
  final samples = Uint16List(64 * 64);
  final _top = Uint16List(258);
  final _left = Uint16List(258);
  final _edge = Uint16List(131);
  final _taps = Uint16List(7);

  void predict(
    Uint16List source,
    int stride,
    int x,
    int y,
    Av1TxSize size, {
    required int depth,
    required Av1IntraMode mode,
    required int angleDelta,
    required bool above,
    required bool left,
    required bool aboveRight,
    required bool belowLeft,
    required int right,
    required int bottom,
    required bool edgeFilter,
    required bool smoothEdge,
    required int? recursiveFilter,
  }) {
    final w = size.width, h = size.height;
    final half = 1 << (depth - 1);
    final at = y * stride + x;
    final aboveFirst = above ? source[at - stride] : half;
    final leftFirst = left ? source[at - 1] : half;
    final corner = above && left
        ? source[at - stride - 1]
        : above
        ? aboveFirst
        : leftFirst;
    _top[1] = _left[1] = corner;
    if (above) {
      final end = math.min(right - 1, x + (aboveRight ? 2 * w : w) - 1);
      for (var i = 0; i < w + h; i++) {
        _top[i + 2] = source[(y - 1) * stride + math.min(end, x + i)];
      }
    } else {
      _top.fillRange(2, w + h + 2, left ? leftFirst : half - 1);
    }
    if (left) {
      final end = math.min(bottom - 1, y + (belowLeft ? 2 * h : h) - 1);
      for (var i = 0; i < w + h; i++) {
        _left[i + 2] = source[math.min(end, y + i) * stride + x - 1];
      }
    } else {
      _left.fillRange(2, w + h + 2, above ? aboveFirst : half + 1);
    }

    if (recursiveFilter != null) {
      _recursive(w, h, recursiveFilter, (1 << depth) - 1);
    } else if (mode == Av1IntraMode.dc || mode == Av1IntraMode.cfl) {
      var sum = 0;
      if (above) {
        for (var i = 0; i < w; i++) {
          sum += _top[i + 2];
        }
      }
      if (left) {
        for (var i = 0; i < h; i++) {
          sum += _left[i + 2];
        }
      }
      final count = (above ? w : 0) + (left ? h : 0);
      samples.fillRange(
        0,
        w * h,
        count == 0 ? half : (sum + (count >> 1)) ~/ count,
      );
    } else if (mode.directional) {
      final angle = _angles[mode.index] + 3 * angleDelta;
      var upTop = 0, upLeft = 0;
      if (edgeFilter && angle != 90 && angle != 180) {
        if (angle > 90 && angle < 180 && w + h >= 24) {
          _top[1] = _left[1] = av1Round(
            5 * _left[2] + 6 * corner + 5 * _top[2],
            4,
          );
        }
        final topCount = angle < 90 ? h : 0;
        final leftCount = angle > 180 ? w : 0;
        final angleTop = (angle - 90).abs(), angleLeft = (angle - 180).abs();
        if (above) {
          _filter(
            _top,
            1 + math.min<int>(w, right - x) + topCount,
            _strength(w + h, smoothEdge, angleTop),
          );
        }
        if (left) {
          _filter(
            _left,
            1 + math.min<int>(h, bottom - y) + leftCount,
            _strength(w + h, smoothEdge, angleLeft),
          );
        }
        final maximum = (1 << depth) - 1;
        if (w + h <= (smoothEdge ? 8 : 16)) {
          if (angleTop > 0 && angleTop < 40) {
            _upsample(_top, w + topCount, maximum);
            upTop = 1;
          }
          if (angleLeft > 0 && angleLeft < 40) {
            _upsample(_left, h + leftCount, maximum);
            upLeft = 1;
          }
        }
      }
      _directional(w, h, angle, upTop, upLeft);
    } else if (mode == Av1IntraMode.paeth) {
      for (var r = 0, out = 0; r < h; r++) {
        final l = _left[r + 2];
        for (var c = 0; c < w; c++) {
          final t = _top[c + 2];
          final dl = (t - corner).abs();
          final dt = (l - corner).abs();
          final dc = (t + l - 2 * corner).abs();
          samples[out++] = dl <= dt && dl <= dc
              ? l
              : dt <= dc
              ? t
              : corner;
        }
      }
    } else {
      final wx = intraSmoothWeights[w.bitLength - 3];
      final wy = intraSmoothWeights[h.bitLength - 3];
      final endTop = _top[w + 1], endLeft = _left[h + 1];
      for (var r = 0, out = 0; r < h; r++) {
        for (var c = 0; c < w; c++) {
          final v = wy[r] * _top[c + 2] + (256 - wy[r]) * endLeft;
          final h = wx[c] * _left[r + 2] + (256 - wx[c]) * endTop;
          samples[out++] = switch (mode) {
            Av1IntraMode.smoothVertical => av1Round(v, 8),
            Av1IntraMode.smoothHorizontal => av1Round(h, 8),
            _ => av1Round(v + h, 9),
          };
        }
      }
    }
  }

  void _directional(int w, int h, int angle, int upTop, int upLeft) {
    final dx = angle < 90
        ? intraDirectionalDerivative[angle]
        : angle > 90 && angle < 180
        ? intraDirectionalDerivative[180 - angle]
        : 0;
    final dy = angle < 180
        ? (angle > 90 ? intraDirectionalDerivative[angle - 90] : 0)
        : angle > 180
        ? intraDirectionalDerivative[270 - angle]
        : 0;
    for (var r = 0, out = 0; r < h; r++) {
      for (var c = 0; c < w; c++) {
        final i = (c << 6) + (angle < 90 ? (r + 1) * dx : -(r + 1) * dx);
        final j = (r << 6) + (angle > 180 ? (c + 1) * dy : -(c + 1) * dy);
        samples[out++] = switch (angle) {
          90 => _top[c + 2],
          180 => _left[r + 2],
          < 90 => _blend(_top, i, upTop, (w + h - 1) << upTop),
          > 180 => _blend(_left, j, upLeft, (w + h - 1) << upLeft),
          _ =>
            i >> (6 - upTop) >= -(1 << upTop)
                ? _blend(_top, i, upTop, w << upTop)
                : _blend(_left, j, upLeft, h << upLeft),
        };
      }
    }
  }

  int _blend(Uint16List edge, int index, int up, int end) {
    final base = index >> (6 - up);
    if (base >= end) return edge[end + 2];
    final fraction = ((index << up) >> 1) & 31;
    return av1Round(
      edge[base + 2] * (32 - fraction) + edge[base + 3] * fraction,
      5,
    );
  }

  void _recursive(int w, int h, int mode, int maximum) {
    final taps = intraRecursiveTaps[mode];
    for (var y = 0; y < h; y += 2) {
      for (var x = 0; x < w; x += 4) {
        for (var i = 0; i < 5; i++) {
          _taps[i] = y == 0
              ? _top[x + i + 1]
              : x == 0 && i == 0
              ? _left[y + 1]
              : samples[(y - 1) * w + x + i - 1];
        }
        for (var i = 0; i < 2; i++) {
          _taps[5 + i] = x == 0
              ? _left[y + i + 2]
              : samples[(y + i) * w + x - 1];
        }
        for (var i = 0; i < 8; i++) {
          var sum = 0;
          for (var j = 0; j < 7; j++) {
            sum += taps[i][j] * _taps[j];
          }
          samples[(y + (i >> 2)) * w + x + (i & 3)] = av1Round(
            sum,
            4,
          ).clamp(0, maximum);
        }
      }
    }
  }

  void _filter(Uint16List values, int count, int strength) {
    if (strength == 0) return;
    _edge.setRange(0, count, values, 1);
    final taps = intraEdgeKernels[strength - 1];
    for (var i = 1; i < count; i++) {
      var sum = 0;
      for (var k = 0; k < 5; k++) {
        sum += taps[k] * _edge[(i + k - 2).clamp(0, count - 1)];
      }
      values[i + 1] = av1Round(sum, 4);
    }
  }

  void _upsample(Uint16List values, int count, int maximum) {
    _edge[0] = values[1];
    _edge.setRange(1, count + 2, values, 1);
    _edge[count + 2] = values[count + 1];
    values[0] = _edge[0];
    for (var i = 0; i < count; i++) {
      final sum = -_edge[i] + 9 * (_edge[i + 1] + _edge[i + 2]) - _edge[i + 3];
      values[2 * i + 1] = av1Round(sum, 4).clamp(0, maximum);
      values[2 * i + 2] = _edge[i + 2];
    }
  }
}

int _strength(int span, bool smooth, int delta) {
  if (smooth) {
    if (span <= 8)
      return delta >= 64
          ? 2
          : delta >= 40
          ? 1
          : 0;
    if (span <= 16)
      return delta >= 48
          ? 2
          : delta >= 20
          ? 1
          : 0;
    if (span <= 24) return delta >= 4 ? 3 : 0;
    return 3;
  }
  if (span <= 8) return delta >= 56 ? 1 : 0;
  if (span <= 16) return delta >= 40 ? 1 : 0;
  if (span <= 24)
    return delta >= 32
        ? 3
        : delta >= 16
        ? 2
        : delta >= 8
        ? 1
        : 0;
  if (span <= 32)
    return delta >= 32
        ? 3
        : delta >= 4
        ? 2
        : 1;
  return 3;
}
