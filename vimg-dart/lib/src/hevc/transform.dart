import 'dart:math' as math;
import 'dart:typed_data';

import 'scaling_lists.dart';
import 'scan.dart';
import 'transform_tables.dart';

final class HevcTransform {
  final _dequantized = Int32List(1024);
  final _vertical = Int32List(1024);
  final _residual = Int32List(1024);

  /// Inverse quantization and reconstruction of a transform block (§8.6).
  Int32List apply(
    Int32List levels,
    int log2,
    int depth,
    int qp, {
    required bool lumaIntra,
    required bool skip,
    required bool bypass,
    Uint8List? weights,
  }) {
    if (bypass) return levels;
    final size = 1 << log2;
    final scale = _levelScale[qp % 6] << (qp ~/ 6);
    final shift = depth + log2 - 5;
    final round = 1 << (shift - 1);
    var maxX = 0, maxY = 0;
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final index = y * size + x;
        final value =
            ((levels[index] * (weights?[index] ?? 16) * scale + round) >> shift)
                .clamp(-32768, 32767);
        _dequantized[index] = value;
        if (value != 0) {
          maxX = math.max(x, maxX);
          maxY = y;
        }
      }
    }

    final outputShift = 20 - depth;
    final outputRound = 1 << (outputShift - 1);
    if (skip) {
      for (var i = 0; i < size * size; i++) {
        _residual[i] =
            ((_dequantized[i] << (5 + log2)) + outputRound) >> outputShift;
      }
      return _residual;
    }

    final basis = log2 == 2 && lumaIntra ? _dst : _dct[log2 - 2];
    for (var y = 0; y < size; y++) {
      final row = basis[y];
      for (var x = 0; x <= maxX; x++) {
        var value = 0;
        for (var k = 0; k <= maxY; k++)
          value += row[k] * _dequantized[k * size + x];
        _vertical[y * size + x] = ((value + 64) >> 7).clamp(-32768, 32767);
      }
    }
    for (var y = 0; y < size; y++) {
      final start = y * size;
      for (var x = 0; x < size; x++) {
        final row = basis[x];
        var value = 0;
        for (var k = 0; k <= maxX; k++) value += row[k] * _vertical[start + k];
        _residual[start + x] = (value + outputRound) >> outputShift;
      }
    }
    return _residual;
  }
}

/// Expand scaling lists to raster factors once per slice configuration.
final class HevcScalingFactors {
  HevcScalingFactors(this.lists);

  final HevcScalingLists? lists;
  final _cache = <(int, int), Uint8List>{};

  Uint8List? weights(int log2, int matrixId) {
    final values = lists;
    if (values == null) return null;
    return _cache.putIfAbsent((log2, matrixId), () {
      final size = 1 << log2;
      final baseLog2 = math.min(3, log2);
      final positions = hevcScans[HevcScan.diagonal.index][baseLog2];
      final matrix = values.matrix(log2 - 2, matrixId);
      final base = Uint8List(positions.length);
      for (var i = 0; i < positions.length; i++) {
        base[positions[i]] = matrix.coefficients[i];
      }
      final enlarge = log2 - baseLog2;
      final result = Uint8List(size * size);
      for (var y = 0; y < size; y++) {
        for (var x = 0; x < size; x++) {
          result[y * size + x] =
              base[((y >> enlarge) << baseLog2) + (x >> enlarge)];
        }
      }
      if (log2 >= 4) result[0] = matrix.dc;
      return result;
    });
  }
}

int hevcChromaQp420(int qp) => qp < 30
    ? qp
    : qp >= 44
    ? qp - 6
    : _chromaMap[qp - 30];

const _chromaMap = [29, 30, 31, 32, 33, 33, 34, 34, 35, 35, 36, 36, 37, 37];
const _levelScale = [40, 45, 51, 57, 64, 72];

final _dct = [
  for (var log2 = 2; log2 <= 5; log2++)
    [
      for (var i = 0; i < 1 << log2; i++)
        [for (var k = 0; k < 1 << log2; k++) hevcDct32[k << (5 - log2)][i]],
    ],
];
final _dst = [
  for (var i = 0; i < 4; i++) [for (var k = 0; k < 4; k++) hevcDst4[k][i]],
];
