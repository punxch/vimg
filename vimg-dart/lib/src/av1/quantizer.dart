import 'dart:typed_data';

import 'frame_parameters.dart';
import 'quantizer_tables.dart';
import 'transform.dart';

/// AV1 §7.12 quantization for one frame. Current Q and segmentation
/// adjustments are supplied by the tile decoder for each block.
final class Av1Quantizer {
  Av1Quantizer(this.parameters, this.depth) : _depthIndex = (depth - 8) >> 1;

  final Av1Quantization parameters;
  final int depth;
  final int _depthIndex;

  bool isLossless(int segmentDelta) =>
      (parameters.base + segmentDelta).clamp(0, 255) == 0 &&
      parameters.yDc == 0 &&
      parameters.uDc == 0 &&
      parameters.uAc == 0 &&
      parameters.vDc == 0 &&
      parameters.vAc == 0;

  /// Dequantizes the compact coefficient raster in place.
  void apply(
    Int32List coefficients,
    Av1TxSize size,
    Av1TxType type,
    int plane, {
    required int currentQ,
    required int segmentDelta,
  }) {
    final index = (currentQ + segmentDelta).clamp(0, 255);
    final (dcDelta, acDelta) = switch (plane) {
      0 => (parameters.yDc, 0),
      1 => (parameters.uDc, parameters.uAc),
      _ => (parameters.vDc, parameters.vAc),
    };
    final dc = av1DcQuantizers[_depthIndex][(index + dcDelta).clamp(0, 255)];
    final ac = av1AcQuantizers[_depthIndex][(index + acDelta).clamp(0, 255)];
    final levels = parameters.matrix;
    final matrixLevel =
        levels == null ||
            type.index >= Av1TxType.identity.index ||
            isLossless(segmentDelta)
        ? 15
        : switch (plane) {
            0 => levels.$1,
            1 => levels.$2,
            _ => levels.$3,
          };
    final matrix = matrixLevel < 15 ? av1QuantizerMatrix(matrixLevel) : null;
    final offset =
        av1MatrixOffset[size.index] + (plane == 0 ? 0 : av1ChromaMatrixOffset);
    final limit = 1 << (depth + 7);
    final shift = size.quantShift;
    final count = size.coefficientWidth * size.coefficientHeight;
    for (var i = 0; i < count; i++) {
      final level = coefficients[i];
      if (level == 0) continue;
      final step = i == 0 ? dc : ac;
      final scaled = matrix == null
          ? step
          : av1Round(step * matrix[offset + i], 5);
      final magnitude = ((level.abs() * scaled) & 0xffffff) >> shift;
      coefficients[i] = (level < 0 ? -magnitude : magnitude).clamp(
        -limit,
        limit - 1,
      );
    }
  }
}
