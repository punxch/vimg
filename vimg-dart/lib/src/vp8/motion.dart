part of 'decoder.dart';

typedef _Vector = (int, int);

const _defaultMv = [
  [
    162,
    128,
    225,
    146,
    172,
    147,
    214,
    39,
    156,
    128,
    129,
    132,
    75,
    145,
    178,
    206,
    239,
    254,
    254,
  ],
  [
    164,
    128,
    204,
    170,
    119,
    235,
    140,
    230,
    228,
    128,
    130,
    130,
    74,
    148,
    180,
    203,
    236,
    254,
    254,
  ],
];
const _updateMv = [
  [
    237,
    246,
    253,
    253,
    254,
    254,
    254,
    254,
    254,
    254,
    254,
    254,
    254,
    254,
    250,
    250,
    252,
    254,
    254,
  ],
  [
    231,
    243,
    245,
    253,
    254,
    254,
    254,
    254,
    254,
    254,
    254,
    254,
    254,
    254,
    251,
    251,
    254,
    254,
    254,
  ],
];
const _modeProbabilities = [
  [7, 1, 1, 143],
  [14, 18, 14, 107],
  [135, 64, 57, 68],
  [60, 56, 128, 65],
  [159, 134, 128, 34],
  [234, 188, 128, 28],
];
const _subVectorProbabilities = [
  [147, 136, 18],
  [106, 145, 1],
  [179, 121, 1],
  [223, 1, 34],
  [208, 1, 1],
];

void _readMotion(
  _BoolReader reader,
  _Entropy entropy,
  _Block block,
  _Block above,
  _Block left,
  _Block diagonal,
  List<bool> biases,
  int column,
  int row,
  int columns,
  int rows,
) {
  final neighbours = [above, left, diagonal];
  final counts = [0, 0, 0, 0];
  final candidates = List<_Vector>.filled(4, (0, 0));
  var slot = 0;
  for (final (i, n) in neighbours.indexed) {
    if (n.reference == 0) continue;
    var (x, y) = n.mv;
    if (biases[n.reference] != biases[block.reference]) {
      x = -x;
      y = -y;
    }
    final value = (x, y);
    if (value == (0, 0)) {
      counts[0] += i == 2 ? 1 : 2;
    } else {
      if (value != candidates[slot]) candidates[++slot] = value;
      counts[slot] += i == 2 ? 1 : 2;
    }
  }
  if (reader.bit(_modeProbabilities[counts[0]][0]) == 0) {
    block.zeroMotion = true;
    return;
  }
  if (counts[3] != 0 && candidates[1] == candidates[3]) {
    counts[1] += counts[3];
  }
  if (counts[2] > counts[1]) {
    final (count, vector) = (counts[1], candidates[1]);
    counts[1] = counts[2];
    candidates[1] = candidates[2];
    counts[2] = count;
    candidates[2] = vector;
  }
  _Vector clamp(_Vector mv) => (
    mv.$1.clamp(-(column + 1) * 64, (columns - column) * 64),
    mv.$2.clamp(-(row + 1) * 64, (rows - row) * 64),
  );

  if (reader.bit(_modeProbabilities[counts[1]][1]) == 0) {
    block.mv = clamp(candidates[1]);
  } else if (reader.bit(_modeProbabilities[counts[2]][2]) == 0) {
    block.mv = clamp(candidates[2]);
  } else {
    final pred = clamp(candidates[counts[1] >= counts[0] ? 1 : 0]);
    final splitCount =
        (above.split == null ? 0 : 2) +
        (left.split == null ? 0 : 2) +
        (diagonal.split == null ? 0 : 1);
    if (reader.bit(_modeProbabilities[splitCount][3]) == 0) {
      block.mv = _addVector(reader, entropy, pred);
    } else {
      final vectors = _splitVectors(reader, entropy, pred, above, left);
      block
        ..split = vectors
        ..mv = vectors.last;
    }
  }
}

_Vector _addVector(_BoolReader reader, _Entropy entropy, _Vector base) {
  final dy = _vectorComponent(reader, entropy.mv[0]);
  final dx = _vectorComponent(reader, entropy.mv[1]);
  return (base.$1 + dx, base.$2 + dy);
}

int _vectorComponent(_BoolReader reader, List<int> p) {
  var magnitude = 0;
  if (reader.bit(p[0]) != 0) {
    for (var bit = 0; bit < 3; bit++) {
      magnitude |= reader.bit(p[9 + bit]) << bit;
    }
    for (var bit = 9; bit >= 4; bit--) {
      magnitude |= reader.bit(p[9 + bit]) << bit;
    }
    if ((magnitude & ~7) == 0 || reader.bit(p[12]) != 0) magnitude += 8;
  } else {
    final high = reader.bit(p[2]);
    final next = 3 + 3 * high;
    final middle = reader.bit(p[next]);
    magnitude = 4 * high + 2 * middle + reader.bit(p[next + 1 + middle]);
  }
  return magnitude != 0 && reader.bit(p[1]) != 0 ? -magnitude : magnitude;
}

List<_Vector> _splitVectors(
  _BoolReader reader,
  _Entropy entropy,
  _Vector base,
  _Block above,
  _Block left,
) {
  final (width, height) = reader.bit(110) == 0
      ? (1, 1)
      : reader.bit(111) == 0
      ? (2, 2)
      : reader.bit(150) == 0
      ? (4, 2)
      : (2, 4);
  final output = List<_Vector>.filled(16, (0, 0));
  for (var y = 0; y < 4; y += height) {
    for (var x = 0; x < 4; x += width) {
      final a = x == 0 ? left.vector(y * 4 + 3) : output[y * 4 + x - 1];
      final b = y == 0 ? above.vector(12 + x) : output[(y - 1) * 4 + x];
      final group = a == b
          ? (a == (0, 0) ? 4 : 3)
          : b == (0, 0)
          ? 2
          : a == (0, 0)
          ? 1
          : 0;
      final p = _subVectorProbabilities[group];
      final mv = reader.bit(p[0]) == 0
          ? a
          : reader.bit(p[1]) == 0
          ? b
          : reader.bit(p[2]) == 0
          ? (0, 0)
          : _addVector(reader, entropy, base);
      for (var j = y; j < y + height; j++) {
        output.fillRange(j * 4 + x, j * 4 + x + width, mv);
      }
    }
  }
  return output;
}

void _predictInter(
  Uint8List scratch,
  Vp8Plane source,
  _Block block,
  int plane,
  int x,
  int y,
  int size,
  int profile,
) {
  final split = block.split != null;
  final step = split ? 4 : size;
  for (var row = 0; row < size; row += step) {
    for (var column = 0; column < size; column += step) {
      var vector = block.mv;
      if (split) {
        if (plane == 0) {
          vector = block.vector(row + column ~/ 4);
        } else {
          final first = row * 2 + column ~/ 2;
          final a = block.vector(first), b = block.vector(first + 1);
          final c = block.vector(first + 4), d = block.vector(first + 5);
          final sx = a.$1 + b.$1 + c.$1 + d.$1;
          final sy = a.$2 + b.$2 + c.$2 + d.$2;
          vector = ((sx + (sx < 0 ? 1 : 2)) >> 2, (sy + (sy < 0 ? 1 : 2)) >> 2);
        }
      }
      var (dx, dy) = vector;
      if (plane == 0) {
        dx *= 2;
        dy *= 2;
      } else if (profile == 3) {
        dx &= ~7;
        dy &= ~7;
      }
      _interpolate(
        scratch,
        source,
        _scratchOrigin + row * kBps + column,
        x + column,
        y + row,
        step,
        dx,
        dy,
        profile == 0,
      );
    }
  }
}

const _sixTap = [
  [0, 0, 128, 0, 0, 0],
  [0, -6, 123, 12, -1, 0],
  [2, -11, 108, 36, -8, 1],
  [0, -9, 93, 50, -6, 0],
  [3, -16, 77, 77, -16, 3],
  [0, -6, 50, 93, -9, 0],
  [1, -8, 36, 108, -11, 2],
  [0, -1, 12, 123, -6, 0],
];

void _interpolate(
  Uint8List output,
  Vp8Plane source,
  int offset,
  int x,
  int y,
  int size,
  int dx,
  int dy,
  bool sixTap,
) {
  x += dx >> 3;
  y += dy >> 3;
  final fx = dx & 7, fy = dy & 7;
  if (fx == 0 && fy == 0) {
    for (var row = 0; row < size; row++) {
      for (var col = 0; col < size; col++) {
        output[offset + row * kBps + col] = source.at(x + col, y + row);
      }
    }
    return;
  }
  final horizontal = sixTap ? _sixTap[fx] : [8 - fx, fx];
  final vertical = sixTap ? _sixTap[fy] : [8 - fy, fy];
  final origin = sixTap ? 2 : 0;
  final shift = sixTap ? 7 : 3;
  final rounding = 1 << (shift - 1);
  final filtered = Uint8List(size * (size + vertical.length - 1));
  for (var row = 0; row < size + vertical.length - 1; row++) {
    for (var col = 0; col < size; col++) {
      var sum = 0;
      for (var tap = 0; tap < horizontal.length; tap++) {
        final weight = horizontal[tap];
        if (weight != 0)
          sum += weight * source.at(x + col + tap - origin, y + row - origin);
      }
      filtered[row * size + col] = ((sum + rounding) >> shift).clamp(0, 255);
    }
  }
  for (var row = 0; row < size; row++) {
    for (var col = 0; col < size; col++) {
      var sum = 0;
      for (var tap = 0; tap < vertical.length; tap++) {
        sum += vertical[tap] * filtered[(row + tap) * size + col];
      }
      output[offset + row * kBps + col] = ((sum + rounding) >> shift).clamp(
        0,
        255,
      );
    }
  }
}
