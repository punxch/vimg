import 'dart:typed_data';

import 'motion.dart';
import 'reference.dart';
import 'slice_header.dart';

/// Inter prediction for progressive 8-bit pictures (§8.4.2.2–8.4.2.3).
void predictL0(
  Uint8List output,
  int plane,
  int mbX,
  int mbY,
  int owner,
  MotionField motion,
  List<ReferencePicture?> references,
  PredictionWeights? weights,
) {
  final luma = plane == 0;
  final block = luma ? 4 : 2;
  final size = block * 4;
  final denominator = luma ? weights?.lumaShift : weights?.chromaShift;
  for (var py = 0; py < 4; py++) {
    for (var px = 0; px < 4; px++) {
      final x = mbX * 4 + px, y = mbY * 4 + py;
      final refIndex = motion.referenceAt(x, y, owner);
      final reference = references[refIndex]?.picture;
      if (reference == null)
        throw const FormatException('H.264 reference picture is unavailable');
      final motionVector = motion.vectorAt(x, y);
      final samples = switch (plane) {
        0 => reference.y,
        1 => reference.cb,
        _ => reference.cr,
      };
      final stride = luma ? reference.stride : reference.stride >> 1;
      final height = samples.length ~/ stride;
      final weight = weights?.l0[refIndex][plane];
      final unit = luma ? 4 : 8;
      final sourceX = x * block * unit + motionVector.x;
      final sourceY = y * block * unit + motionVector.y;
      final targetX = px * block, targetY = py * block;
      for (var row = 0; row < block; row++) {
        for (var col = 0; col < block; col++) {
          var sample = luma
              ? _luma(
                  samples,
                  stride,
                  height,
                  sourceX + col * unit,
                  sourceY + row * unit,
                )
              : _chroma(
                  samples,
                  stride,
                  height,
                  sourceX + col * unit,
                  sourceY + row * unit,
                );
          if (weight != null) {
            sample = _weighted(sample, weight, denominator!);
          }
          output[(targetY + row) * size + targetX + col] = sample;
        }
      }
    }
  }
}

int _weighted(int sample, PredictionWeight weight, int shift) {
  final round = shift == 0 ? 0 : 1 << (shift - 1);
  return (((sample * weight.weight + round) >> shift) + weight.offset).clamp(
    0,
    255,
  );
}

int _sample(Uint8List data, int stride, int height, int x, int y) =>
    data[y.clamp(0, height - 1) * stride + x.clamp(0, stride - 1)];

int _chroma(Uint8List data, int stride, int height, int x8, int y8) {
  final x = x8 >> 3, y = y8 >> 3;
  final dx = x8 & 7, dy = y8 & 7;
  final a = _sample(data, stride, height, x, y);
  if (dx == 0 && dy == 0) return a;
  final b = _sample(data, stride, height, x + 1, y);
  final c = _sample(data, stride, height, x, y + 1);
  final d = _sample(data, stride, height, x + 1, y + 1);
  return ((8 - dx) * ((8 - dy) * a + dy * c) +
          dx * ((8 - dy) * b + dy * d) +
          32) >>
      6;
}

int _luma(Uint8List data, int stride, int height, int x4, int y4) {
  final x = x4 >> 2, y = y4 >> 2;
  final dx = x4 & 3, dy = y4 & 3;
  if (dx == 0 && dy == 0) return _sample(data, stride, height, x, y);
  if (dy == 0) {
    final half = _halfX(data, stride, height, x, y);
    return dx == 2
        ? half
        : _average(half, _sample(data, stride, height, x + (dx >> 1), y));
  }
  if (dx == 0) {
    final half = _halfY(data, stride, height, x, y);
    return dy == 2
        ? half
        : _average(half, _sample(data, stride, height, x, y + (dy >> 1)));
  }
  if (dx == 2 || dy == 2) {
    final half = _diagonal(data, stride, height, x, y);
    if (dx == 2 && dy == 2) return half;
    return dx == 2
        ? _average(half, _halfX(data, stride, height, x, y + (dy >> 1)))
        : _average(half, _halfY(data, stride, height, x + (dx >> 1), y));
  }
  return _average(
    _halfX(data, stride, height, x, y + (dy >> 1)),
    _halfY(data, stride, height, x + (dx >> 1), y),
  );
}

int _average(int a, int b) => (a + b + 1) >> 1;

int _six(int a, int b, int c, int d, int e, int f) =>
    a - 5 * (b + e) + 20 * (c + d) + f;

int _horizontal(Uint8List data, int stride, int height, int x, int y) {
  final row = y.clamp(0, height - 1) * stride;
  if (x >= 2 && x + 3 < stride) {
    final p = row + x;
    return _six(
      data[p - 2],
      data[p - 1],
      data[p],
      data[p + 1],
      data[p + 2],
      data[p + 3],
    );
  }
  int at(int offset) => data[row + (x + offset).clamp(0, stride - 1)];
  return _six(at(-2), at(-1), at(0), at(1), at(2), at(3));
}

int _halfX(Uint8List data, int stride, int height, int x, int y) =>
    ((_horizontal(data, stride, height, x, y) + 16) >> 5).clamp(0, 255);

int _halfY(Uint8List data, int stride, int height, int x, int y) {
  final column = x.clamp(0, stride - 1);
  if (y >= 2 && y + 3 < height) {
    final p = y * stride + column;
    return ((_six(
                  data[p - 2 * stride],
                  data[p - stride],
                  data[p],
                  data[p + stride],
                  data[p + 2 * stride],
                  data[p + 3 * stride],
                ) +
                16) >>
            5)
        .clamp(0, 255);
  }
  int at(int offset) =>
      data[(y + offset).clamp(0, height - 1) * stride + column];
  return ((_six(at(-2), at(-1), at(0), at(1), at(2), at(3)) + 16) >> 5).clamp(
    0,
    255,
  );
}

int _diagonal(Uint8List data, int stride, int height, int x, int y) {
  int at(int offset) => _horizontal(data, stride, height, x, y + offset);
  return ((_six(at(-2), at(-1), at(0), at(1), at(2), at(3)) + 512) >> 10).clamp(
    0,
    255,
  );
}
