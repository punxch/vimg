part of 'decoder.dart';

typedef _H263IntraBlock = ({int dc, Int16List edges});

extension _H263AdvancedIntra on _H263Macroblocks {
  void _reconstructAic(int plane, int bx, int by, int quant, bool? fromLeft) {
    final sub = plane == 0 ? 1 : 0;
    final columns = picture.columns << sub;
    final blocks = _aic[plane];
    _H263IntraBlock? neighbor(int x, int y) {
      if (x < 0 ||
          y < 0 ||
          (y >> sub) * picture.columns + (x >> sub) < _sliceStart) {
        return null;
      }
      return blocks[y * columns + x];
    }

    final left = neighbor(bx - 1, by), top = neighbor(bx, by - 1);
    final reference = fromLeft == null ? null : (fromLeft ? left : top);
    final int prediction;
    if (fromLeft != null) {
      prediction = reference?.dc ?? 1024;
    } else if (left != null && top != null) {
      prediction = (left.dc + top.dc) >> 1;
    } else {
      prediction = left?.dc ?? top?.dc ?? 1024;
    }
    final values = _coefficients;
    final dc = values[0] * 2 * quant + prediction;
    values[0] = dc < 0 ? 0 : (dc | 1).clamp(0, 2047);
    for (var i = 1; i < 64; i++) {
      int base = 0;
      if (reference != null) {
        if (fromLeft == true && i & 7 == 0) {
          base = reference.edges[8 + (i >> 3)];
        } else if (fromLeft == false && i < 8) {
          base = reference.edges[i];
        }
      }
      values[i] = (values[i] * 2 * quant + base).clamp(-2048, 2047);
    }
    // Annex I predicts from the reconstructed coefficients. Retain the row
    // and column after inverse quantization so neighboring QUANTs may differ.
    final edges = Int16List(16);
    for (var i = 1; i < 8; i++) {
      edges[i] = values[i];
      edges[8 + i] = values[i * 8];
    }
    blocks[by * columns + bx] = (dc: values[0], edges: edges);
  }
}

const _filterStrength = [
  0,
  1,
  1,
  2,
  2,
  3,
  3,
  4,
  4,
  4,
  5,
  5,
  6,
  6,
  7,
  7,
  7,
  8,
  8,
  8,
  9,
  9,
  9,
  10,
  10,
  10,
  11,
  11,
  11,
  12,
  12,
  12,
];

void _deblockH263(
  H263Picture picture,
  Uint8List quantizers, {
  required bool modifiedQuant,
}) {
  final columns = picture.columns, rows = picture.rows;
  final luma = picture.planes[0];
  final stride = picture.stride, chromaStride = stride >> 1;
  void lumaEdge(int x, int y, int quant, {required bool vertical}) {
    _filterH263Edge(
      luma,
      y * stride + x,
      vertical ? 1 : stride,
      vertical ? stride : 1,
      _filterStrength[quant],
    );
  }

  void chromaEdge(int x, int y, int quant, {required bool vertical}) {
    final strength =
        _filterStrength[modifiedQuant ? _h263ChromaQuant[quant] : quant];
    for (var i = 1; i < 3; i++) {
      _filterH263Edge(
        picture.planes[i],
        y * chromaStride + x,
        vertical ? 1 : chromaStride,
        vertical ? chromaStride : 1,
        strength,
      );
    }
  }

  for (var y = 0; y < rows; y++) {
    for (var x = 0; x < columns; x++) {
      final index = y * columns + x;
      final lx = x * 16, ly = y * 16, cx = x * 8, cy = y * 8;
      final current = quantizers[index];
      final lastRow = y == rows - 1;
      if (current != 0) {
        lumaEdge(lx, ly + 8, current, vertical: false);
        lumaEdge(lx + 8, ly + 8, current, vertical: false);
      }
      // Finish horizontal edges before their intersecting vertical edges.
      // The lower half of a vertical edge waits until the next row arrives.
      if (y != 0) {
        final above = quantizers[index - columns];
        final topEdge = current != 0 ? current : above;
        if (topEdge != 0) {
          lumaEdge(lx, ly, topEdge, vertical: false);
          lumaEdge(lx + 8, ly, topEdge, vertical: false);
          chromaEdge(cx, cy, topEdge, vertical: false);
        }
        if (above != 0) lumaEdge(lx + 8, ly - 8, above, vertical: true);
        if (x != 0) {
          final upperLeft = above != 0
              ? above
              : quantizers[index - columns - 1];
          if (upperLeft != 0) {
            lumaEdge(lx, ly - 8, upperLeft, vertical: true);
            chromaEdge(cx, cy - 8, upperLeft, vertical: true);
          }
        }
      }
      if (current != 0) {
        lumaEdge(lx + 8, ly, current, vertical: true);
        if (lastRow) lumaEdge(lx + 8, ly + 8, current, vertical: true);
      }
      if (x != 0) {
        final leftEdge = current != 0 ? current : quantizers[index - 1];
        if (leftEdge != 0) {
          lumaEdge(lx, ly, leftEdge, vertical: true);
          if (lastRow) {
            lumaEdge(lx, ly + 8, leftEdge, vertical: true);
            chromaEdge(cx, cy, leftEdge, vertical: true);
          }
        }
      }
    }
  }
}

void _filterH263Edge(
  Uint8List plane,
  int offset,
  int across,
  int along,
  int strength,
) {
  for (var i = 0; i < 8; i++, offset += along) {
    final a = offset - 2 * across, b = offset - across, d = offset + across;
    final outer = plane[a] - plane[d];
    final difference = (outer + 4 * (plane[offset] - plane[b])) ~/ 8;
    final magnitude = difference.abs();
    final inner = math.max(0, math.min(magnitude, 2 * strength - magnitude));
    final adjustment = difference.sign * inner;
    plane[b] = (plane[b] + adjustment).clamp(0, 255);
    plane[offset] = (plane[offset] - adjustment).clamp(0, 255);
    final half = inner >> 1;
    final outerAdjustment = (outer ~/ 4).clamp(-half, half);
    plane[a] -= outerAdjustment;
    plane[d] += outerAdjustment;
  }
}

final _aicEvents = _Events(_aicCodes, _aicRuns, _aicLevels, 58);

// H.263 Advanced INTRA TCOEF and modified quantization tables.
const _aicCodes = <int>[
  // dart format off
  2, 2, 6, 3, 14, 4, 12, 5, 13, 5, 16, 6,
  17, 6, 18, 6, 22, 7, 27, 8, 32, 9, 33, 9,
  26, 9, 27, 9, 28, 9, 29, 9, 30, 9, 31, 9,
  35, 11, 34, 11, 87, 12, 86, 12, 85, 12, 84, 12,
  83, 12, 15, 4, 20, 6, 20, 7, 30, 8, 15, 10,
  33, 11, 80, 12, 11, 5, 21, 7, 14, 10, 9, 10,
  21, 6, 29, 8, 13, 10, 81, 12, 19, 6, 35, 9,
  7, 11, 23, 7, 34, 9, 82, 12, 28, 8, 12, 10,
  31, 8, 11, 10, 37, 9, 10, 10, 36, 9, 6, 11,
  33, 10, 32, 10, 8, 10, 32, 11, 7, 4, 12, 6,
  16, 7, 19, 8, 17, 9, 18, 9, 4, 10, 39, 11,
  38, 11, 95, 12, 15, 6, 19, 9, 5, 10, 37, 11,
  14, 6, 20, 9, 36, 11, 13, 6, 6, 10, 94, 12,
  17, 7, 7, 10, 19, 7, 93, 12, 18, 7, 92, 12,
  20, 8, 91, 12, 21, 8, 26, 8, 25, 8, 24, 8,
  23, 8, 22, 8, 25, 9, 21, 9, 22, 9, 24, 9,
  23, 9, 4, 11, 5, 11, 88, 12, 89, 12, 90, 12,
  3, 7,
  // dart format on
];

const _aicRuns = <int>[
  // dart format off
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1,
  2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 5, 5, 5, 6, 6,
  7, 7, 8, 8, 9, 9, 10, 11, 12, 13, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4,
  5, 5, 6, 6, 7, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17,
  18, 19, 20, 21, 22, 23,
  // dart format on
];

const _aicLevels = <int>[
  // dart format off
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
  17, 18, 19, 20, 21, 22, 23, 24, 25, 1, 2, 3, 4, 5, 6, 7,
  1, 2, 3, 4, 1, 2, 3, 4, 1, 2, 3, 1, 2, 3, 1, 2,
  1, 2, 1, 2, 1, 2, 1, 1, 1, 1, 1, 2, 3, 4, 5, 6,
  7, 8, 9, 10, 1, 2, 3, 4, 1, 2, 3, 1, 2, 3, 1, 2,
  1, 2, 1, 2, 1, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 1, 1, 1, 1,
  // dart format on
];

const _h263ChromaQuant = <int>[
  // dart format off
  0, 1, 2, 3, 4, 5, 6, 6, 7, 8, 9, 9, 10, 10, 11, 11,
  12, 12, 12, 13, 13, 13, 14, 14, 14, 14, 14, 15, 15, 15, 15, 15,
  // dart format on
];

const _h263QuantChange = <List<int>>[
  // dart format off
  [
    0, 3, 1, 2, 3, 4, 5, 6, 7, 8, 9, 9, 10, 11, 12, 13,
    14, 15, 16, 17, 18, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28,
  ],
  [
    0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 14, 15, 16, 17,
    18, 19, 20, 21, 22, 24, 25, 26, 27, 28, 29, 30, 31, 31, 31, 26,
  ],
  // dart format on
];
