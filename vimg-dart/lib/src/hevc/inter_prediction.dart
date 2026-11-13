import 'dart:typed_data';

import 'decoded_pictures.dart';
import 'motion_field.dart';
import 'picture.dart';
import 'slice_header.dart';

/// Fractional-sample interpolation and weighted prediction (H.265 §8.5.3.3).
final class HevcInterPrediction {
  final _l0 = Int32List(64 * 64);
  final _l1 = Int32List(64 * 64);
  final _rows = Int32List(64 * (64 + 7));

  void reconstruct(
    HevcPicture picture,
    HevcBlock block,
    HevcMotionPair motion,
    HevcReferenceLists references,
    HevcWeights? weights,
  ) {
    final m0 = motion.l0, m1 = motion.l1;
    final p0 = m0 == null ? null : references.l0[m0.index].picture;
    final p1 = m1 == null ? null : references.l1[m1.index].picture;
    _plane(picture.luma, p0?.luma, p1?.luma, block, motion, weights, 0, 0, 0);
    if (picture.cb != null) {
      final sx = picture.sps.chromaShiftX, sy = picture.sps.chromaShiftY;
      _plane(picture.cb!, p0?.cb, p1?.cb, block, motion, weights, 1, sx, sy);
      _plane(picture.cr!, p0?.cr, p1?.cr, block, motion, weights, 2, sx, sy);
    }
  }

  void _plane(
    HevcPlane destination,
    HevcPlane? plane0,
    HevcPlane? plane1,
    HevcBlock b,
    HevcMotionPair motion,
    HevcWeights? weights,
    int component,
    int sx,
    int sy,
  ) {
    final chroma = component != 0;
    final x = b.x >> sx, y = b.y >> sy;
    final w = b.width >> sx, h = b.height >> sy;
    final m0 = motion.l0, m1 = motion.l1;
    if (m0 != null)
      _interpolate(plane0!, _l0, x, y, w, h, m0.vector, chroma, sx, sy);
    if (m1 != null)
      _interpolate(plane1!, _l1, x, y, w, h, m1.vector, chroma, sx, sy);
    final bi = m0 != null && m1 != null;
    final shift =
        14 -
        destination.depth +
        (weights == null
            ? 0
            : chroma
            ? weights.chromaShift
            : weights.lumaShift);
    final weight0 = m0 == null ? null : weights?.l0[m0.index][component];
    final weight1 = m1 == null ? null : weights?.l1[m1.index][component];
    final w0 = m0 == null ? 0 : weight0?.weight ?? 1;
    final w1 = m1 == null ? 0 : weight1?.weight ?? 1;
    final o0 = weight0?.offset ?? 0;
    final o1 = weight1?.offset ?? 0;
    final offset = bi ? 0 : o0 + o1;
    final round = bi ? (o0 + o1 + 1) << shift : 1 << (shift - 1);
    final finalShift = shift + (bi ? 1 : 0);
    for (var row = 0; row < h; row++) {
      final dst = (y + row) * destination.width + x, src = row * w;
      for (var col = 0; col < w; col++) {
        final i = src + col;
        final value =
            ((_l0[i] * w0 + _l1[i] * w1 + round) >> finalShift) + offset;
        destination.samples[dst + col] = value.clamp(0, destination.maximum);
      }
    }
  }

  void _interpolate(
    HevcPlane plane,
    Int32List out,
    int x,
    int y,
    int w,
    int h,
    HevcVector vector,
    bool chroma,
    int shiftX,
    int shiftY,
  ) {
    final precisionX = 2 + shiftX, precisionY = 2 + shiftY;
    final sx = x + (vector.x >> precisionX), sy = y + (vector.y >> precisionY);
    final fx =
        (vector.x & ((1 << precisionX) - 1)) << (chroma ? 1 - shiftX : 0);
    final fy =
        (vector.y & ((1 << precisionY) - 1)) << (chroma ? 1 - shiftY : 0);
    final source = plane.samples, stride = plane.width;
    final lastX = stride - 1, lastY = plane.height - 1;
    final depthShift = plane.depth - 8;
    if (fx == 0 && fy == 0) {
      final shift = 14 - plane.depth;
      for (var row = 0; row < h; row++) {
        final src = (sy + row).clamp(0, lastY) * stride, dst = row * w;
        for (var col = 0; col < w; col++) {
          out[dst + col] = source[src + (sx + col).clamp(0, lastX)] << shift;
        }
      }
      return;
    }
    final filters = chroma ? _chroma : _luma;
    final taps = filters.first.length;
    final lead = taps ~/ 2 - 1;
    if (fx != 0) {
      final kernel = filters[fx];
      final end = fy == 0 ? h : h + taps - 1;
      final first = fy == 0 ? sy : sy - lead;
      final horizontal = fy == 0 ? out : _rows;
      for (var row = 0; row < end; row++) {
        final src = (first + row).clamp(0, lastY) * stride, dst = row * w;
        for (var col = 0; col < w; col++) {
          var sum = 0;
          final start = sx + col - lead;
          for (var i = 0; i < taps; i++) {
            sum += kernel[i] * source[src + (start + i).clamp(0, lastX)];
          }
          horizontal[dst + col] = sum >> depthShift;
        }
      }
    }
    if (fy == 0) return;
    final kernel = filters[fy];
    for (var row = 0; row < h; row++) {
      final dst = row * w;
      if (fx != 0) {
        for (var col = 0; col < w; col++) {
          var sum = 0;
          for (var i = 0; i < taps; i++) {
            sum += kernel[i] * _rows[dst + col + i * w];
          }
          out[dst + col] = sum >> 6;
        }
      } else {
        for (var col = 0; col < w; col++) {
          var sum = 0;
          final cx = (sx + col).clamp(0, lastX);
          for (var i = 0; i < taps; i++) {
            final cy = (sy + row - lead + i).clamp(0, lastY);
            sum += kernel[i] * source[cy * stride + cx];
          }
          out[dst + col] = sum >> depthShift;
        }
      }
    }
  }
}

const _luma = [
  [0, 0, 0, 64, 0, 0, 0, 0],
  [-1, 4, -10, 58, 17, -5, 1, 0],
  [-1, 4, -11, 40, 40, -11, 4, -1],
  [0, 1, -5, 17, 58, -10, 4, -1],
];

const _chroma = [
  [0, 64, 0, 0],
  [-2, 58, 10, -2],
  [-4, 54, 16, -2],
  [-6, 46, 28, -4],
  [-4, 36, 36, -4],
  [-4, 28, 46, -6],
  [-2, 16, 54, -4],
  [-2, 10, 58, -2],
];
