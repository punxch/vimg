part of 'decoder.dart';

/// Intra prediction uses reconstructed neighbors before loop filtering.
final class _IntraPrediction {
  final _top = Int32List(64);
  final _left = Int32List(32);

  void predict(
    Vp9Plane plane,
    int x,
    int y,
    int size,
    int mode, {
    required bool haveAbove,
    required bool haveLeft,
    required bool haveAboveRight,
    required int midpoint,
  }) {
    final pixels = plane.samples, stride = plane.stride;
    final maxX = plane.paddedWidth - 1, maxY = plane.paddedHeight - 1;
    var sum = 0, count = 0;
    for (var i = 0; i < size; i++) {
      _top[i] = haveAbove
          ? pixels[(y - 1) * stride + math.min(x + i, maxX)]
          : midpoint - 1;
      _left[i] = haveLeft
          ? pixels[math.min(y + i, maxY) * stride + x - 1]
          : midpoint + 1;
      if (mode == 0) {
        if (haveAbove) sum += _top[i];
        if (haveLeft) sum += _left[i];
      }
    }
    if (haveAbove) count += size;
    if (haveLeft) count += size;
    final dc = count == 0 ? midpoint : (sum + (count >> 1)) ~/ count;
    for (var i = size; i < size * 2; i++) {
      _top[i] = haveAbove && haveAboveRight && size == 4
          ? pixels[(y - 1) * stride + math.min(x + i, maxX)]
          : _top[size - 1];
    }
    final corner = haveAbove
        ? (haveLeft ? pixels[(y - 1) * stride + x - 1] : midpoint + 1)
        : midpoint - 1;
    int diagonal(int i) => i == 0
        ? corner
        : i > 0
        ? _top[i - 1]
        : _left[-i - 1];
    int left(int i) => _left[math.min(i, size - 1)];
    int average(int a, int b) => (a + b + 1) >> 1;
    int weighted(int a, int b, int c) => (a + 2 * b + c + 2) >> 2;
    for (var row = 0; row < size; row++) {
      final start = (y + row) * stride + x;
      for (var col = 0; col < size; col++) {
        final position = start + col;
        final top = col + (row >> 1), leftIndex = row + (col >> 1);
        final value = switch (mode) {
          0 => dc,
          1 => _top[col],
          2 => _left[row],
          3 =>
            row + col + 2 < size * 2
                ? weighted(
                    _top[row + col],
                    _top[row + col + 1],
                    _top[row + col + 2],
                  )
                : _top[size * 2 - 1],
          4 => weighted(
            diagonal(col - row - 1),
            diagonal(col - row),
            diagonal(col - row + 1),
          ),
          5 =>
            row >= 2 && col > 0
                ? pixels[position - 2 * stride - 1]
                : row == 0
                ? average(diagonal(col), diagonal(col + 1))
                : weighted(
                    diagonal(col - row),
                    diagonal(col - row + 1),
                    diagonal(col - row + 2),
                  ),
          6 =>
            col >= 2 && row > 0
                ? pixels[position - stride - 2]
                : col == 0
                ? average(diagonal(-row), diagonal(-row - 1))
                : weighted(
                    diagonal(col - row - 2),
                    diagonal(col - row - 1),
                    diagonal(col - row),
                  ),
          7 =>
            col.isEven
                ? average(left(leftIndex), left(leftIndex + 1))
                : weighted(
                    left(leftIndex),
                    left(leftIndex + 1),
                    left(leftIndex + 2),
                  ),
          8 =>
            row.isEven
                ? average(_top[top], _top[top + 1])
                : weighted(_top[top], _top[top + 1], _top[top + 2]),
          _ => (_top[col] + _left[row] - corner).clamp(0, midpoint * 2 - 1),
        };
        pixels[position] = value;
      }
    }
  }
}
