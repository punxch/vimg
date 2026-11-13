import 'dart:math' as math;
import 'dart:typed_data';

typedef Neighbors = ({bool left, bool top, bool corner, bool topRight});

/// Reusable reference and prediction buffers for H.264 intra prediction.
final class IntraPrediction {
  IntraPrediction(int depth)
    : pixels = depth == 8 ? Uint8List(256) : Uint16List(256),
      _midpoint = 1 << (depth - 1),
      maximum = (1 << depth) - 1;

  final List<int> pixels;
  final int _midpoint, maximum;
  final _top = Uint16List(16);
  final _left = Uint16List(16);
  final _raw = Uint16List(16);
  var _corner = 0;

  void luma(
    List<int> plane,
    int stride,
    int start,
    int size,
    int mode,
    Neighbors available,
  ) {
    _references(
      plane,
      stride,
      start,
      size,
      available,
      directional: size < 16,
      filtered: size == 8,
    );
    if (mode == 2) {
      pixels.fillRange(0, size * size, _dc(size, available));
    } else if (size == 16) {
      _large(size, mode, available);
    } else {
      for (var y = 0; y < size; y++) {
        for (var x = 0; x < size; x++) {
          pixels[y * size + x] = switch (mode) {
            0 => _top[x],
            1 => _left[y],
            3 => _quarter(
              _top[x + y],
              _top[x + y + 1],
              _top[math.min(2 * size - 1, x + y + 2)],
            ),
            4 => _diagonalAverage(x - y, false),
            5 => _verticalRight(x, y, false),
            6 => _verticalRight(y, x, true),
            7 => _along(_top, x, y, 2 * size - 1),
            8 => _along(_left, y, x, size - 1),
            _ => throw const FormatException(
              'Invalid H.264 intra prediction mode',
            ),
          };
        }
      }
    }
  }

  void chroma(
    List<int> plane,
    int stride,
    int start,
    int mode,
    Neighbors available,
  ) {
    const size = 8;
    _references(plane, stride, start, size, available);
    if (mode != 0) {
      _large(size, mode == 2 ? 0 : mode, available);
      return;
    }
    // A chroma macroblock has one DC predictor per 4×4 quadrant.
    for (var by = 0; by < 8; by += 4) {
      for (var bx = 0; bx < 8; bx += 4) {
        final useTop = available.top && (bx != 0 || by == 0 || !available.left);
        final useLeft =
            available.left && (by != 0 || bx == 0 || !available.top);
        var count = 0, sum = 0;
        for (var i = 0; i < 4; i++) {
          if (useTop) {
            sum += _top[bx + i];
            count++;
          }
          if (useLeft) {
            sum += _left[by + i];
            count++;
          }
        }
        final value = count == 0 ? _midpoint : (sum + count ~/ 2) ~/ count;
        for (var i = 0; i < 4; i++) {
          final offset = (by + i) * size + bx;
          pixels.fillRange(offset, offset + 4, value);
        }
      }
    }
  }

  void _references(
    List<int> plane,
    int stride,
    int start,
    int size,
    Neighbors available, {
    bool directional = false,
    bool filtered = false,
  }) {
    final corner = available.corner ? plane[start - stride - 1] : 0;
    if (available.top) {
      final offset = start - stride;
      _top.setRange(0, size, plane, offset);
      if (directional) {
        if (available.topRight) {
          _top.setRange(size, 2 * size, plane, offset + size);
        } else {
          _top.fillRange(size, 2 * size, _top[size - 1]);
        }
      }
    }
    if (available.left) {
      for (var i = 0; i < size; i++) {
        _left[i] = plane[start - 1 + i * stride];
      }
    }
    _corner = corner;
    if (!filtered) return;
    if (available.corner) {
      _corner = _quarter(
        available.left ? _left[0] : corner,
        corner,
        available.top ? _top[0] : corner,
      );
    }
    if (available.top)
      _smooth(_top, 2 * size, available.corner ? corner : _top[0]);
    if (available.left)
      _smooth(_left, size, available.corner ? corner : _left[0]);
  }

  void _smooth(Uint16List edge, int length, int preceding) {
    _raw.setRange(0, length, edge);
    for (var i = 0; i < length; i++) {
      edge[i] = _quarter(
        i == 0 ? preceding : _raw[i - 1],
        _raw[i],
        _raw[math.min(i + 1, length - 1)],
      );
    }
  }

  int _dc(int size, Neighbors available) {
    var sum = 0;
    for (var i = 0; i < size; i++) {
      if (available.top) sum += _top[i];
      if (available.left) sum += _left[i];
    }
    final count = (available.top ? size : 0) + (available.left ? size : 0);
    return count == 0 ? _midpoint : (sum + count ~/ 2) ~/ count;
  }

  void _large(int size, int mode, Neighbors available) {
    if ((mode == 0 && !available.top) ||
        (mode == 1 && !available.left) ||
        (mode == 3 && !(available.left && available.top && available.corner))) {
      throw const FormatException(
        'Unavailable H.264 intra prediction reference',
      );
    }
    var a = 0, b = 0, c = 0;
    final half = size ~/ 2;
    if (mode == 3) {
      var h = 0, v = 0;
      for (var i = 1; i <= half; i++) {
        final lo = half - 1 - i;
        final hi = half - 1 + i;
        h += i * (_top[hi] - (lo < 0 ? _corner : _top[lo]));
        v += i * (_left[hi] - (lo < 0 ? _corner : _left[lo]));
      }
      final scale = size == 16 ? 5 : 34;
      a = 16 * (_top[size - 1] + _left[size - 1]);
      b = (scale * h + 32) >> 6;
      c = (scale * v + 32) >> 6;
    }
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        pixels[y * size + x] = switch (mode) {
          0 => _top[x],
          1 => _left[y],
          3 => ((a + b * (x - half + 1) + c * (y - half + 1) + 16) >> 5).clamp(
            0,
            maximum,
          ),
          _ => throw const FormatException(
            'Invalid H.264 block prediction mode',
          ),
        };
      }
    }
  }

  int _diagonal(int position, bool transpose) {
    if (position == 0) return _corner;
    if (transpose) position = -position;
    return position > 0 ? _top[position - 1] : _left[-position - 1];
  }

  int _diagonalAverage(int position, bool transpose) => _quarter(
    _diagonal(position - 1, transpose),
    _diagonal(position, transpose),
    _diagonal(position + 1, transpose),
  );

  int _verticalRight(int x, int y, bool transpose) {
    final slope = 2 * x - y;
    if (slope < 0) return _diagonalAverage(slope + 1, transpose);
    if (slope.isOdd) return _diagonalAverage((slope + 1) >> 1, transpose);
    final p = slope >> 1;
    return _half(_diagonal(p, transpose), _diagonal(p + 1, transpose));
  }

  int _along(Uint16List edge, int x, int y, int last) {
    final i = math.min(x + (y >> 1), last);
    final j = math.min(i + 1, last);
    return y.isEven
        ? _half(edge[i], edge[j])
        : _quarter(edge[i], edge[j], edge[math.min(j + 1, last)]);
  }
}

int _half(int a, int b) => (a + b + 1) >> 1;
int _quarter(int a, int b, int c) => (a + 2 * b + c + 2) >> 2;
