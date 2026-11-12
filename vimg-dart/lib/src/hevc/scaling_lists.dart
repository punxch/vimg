import 'dart:typed_data';

import '../rbsp.dart';

typedef HevcScalingMatrix = ({int dc, Uint8List coefficients});

/// Coefficients are stored in the diagonal scan order of §7.3.4.
final class HevcScalingLists {
  const HevcScalingLists.defaults() : _matrices = const {};
  HevcScalingLists._(this._matrices);

  factory HevcScalingLists.read(Rbsp bits) {
    final matrices = <(int, int), HevcScalingMatrix>{};
    for (var size = 0; size < 4; size++) {
      final step = size == 3 ? 3 : 1;
      for (var id = 0; id < 6; id += step) {
        if (!bits.flag()) {
          final delta = bits.ue(id ~/ step);
          if (delta != 0) {
            final from = id - delta * step;
            matrices[(size, id)] =
                matrices[(size, from)] ?? _defaultMatrix(size, from);
          }
          continue;
        }
        final dc = size >= 2 ? 8 + bits.se() : 16;
        if (dc < 1 || dc > 255)
          throw const FormatException('Invalid HEVC scaling list DC');
        var next = size >= 2 ? dc : 8;
        final coefficients = Uint8List(size == 0 ? 16 : 64);
        for (var i = 0; i < coefficients.length; i++) {
          final delta = bits.se();
          if (delta < -128 || delta > 127)
            throw const FormatException('Invalid HEVC scaling list delta');
          next = (next + delta) & 255;
          coefficients[i] = next;
        }
        matrices[(size, id)] = (dc: dc, coefficients: coefficients);
      }
    }
    return HevcScalingLists._(matrices);
  }

  final Map<(int, int), HevcScalingMatrix> _matrices;

  HevcScalingMatrix matrix(int sizeId, int matrixId) =>
      _matrices[(sizeId, matrixId)] ?? _defaultMatrix(sizeId, matrixId);
}

HevcScalingMatrix _defaultMatrix(int size, int id) =>
    size == 0 ? _flat4 : (id < 3 ? _intra8 : _inter8);

final _flat4 = (dc: 16, coefficients: Uint8List(16)..fillRange(0, 16, 16));
final _intra8 = (dc: 16, coefficients: _diagonal(_defaultIntra));
final _inter8 = (dc: 16, coefficients: _diagonal(_defaultInter));

Uint8List _diagonal(List<int> raster) => Uint8List.fromList([
  for (var sum = 0; sum <= 14; sum++)
    for (var x = 0; x < 8; x++)
      if (sum - x >= 0 && sum - x < 8) raster[(sum - x) * 8 + x],
]);

// H.265 Tables 7-6 and 7-7, in raster order.
// dart format off
const _defaultIntra = [
  16, 16, 16, 16, 17, 18, 21, 24,
  16, 16, 16, 16, 17, 19, 22, 25,
  16, 16, 17, 18, 20, 22, 25, 29,
  16, 16, 18, 21, 24, 27, 31, 36,
  17, 17, 20, 24, 30, 35, 41, 47,
  18, 19, 22, 27, 35, 44, 54, 65,
  21, 22, 25, 31, 41, 54, 70, 88,
  24, 25, 29, 36, 47, 65, 88, 115,
];
const _defaultInter = [
  16, 16, 16, 16, 17, 18, 20, 24,
  16, 16, 16, 17, 18, 20, 24, 25,
  16, 16, 17, 18, 20, 24, 25, 28,
  16, 17, 18, 20, 24, 25, 28, 33,
  17, 18, 20, 24, 25, 28, 33, 41,
  18, 20, 24, 25, 28, 33, 41, 54,
  20, 24, 25, 28, 33, 41, 54, 71,
  24, 25, 28, 33, 41, 54, 71, 91,
];
