import 'dart:typed_data';

import 'deblock_tables.dart';
import 'intra_blocks.dart';
import 'transforms.dart';

/// H.264 deblocking for an intra picture (§8.7). The filter is applied in
/// macroblock order after intra prediction has read the unfiltered planes.
void deblockIntra(
  List<IntraBlock?> blocks,
  Uint8List y,
  Uint8List cb,
  Uint8List cr,
  int width,
) {
  final stride = width * 16;
  for (var address = 0; address < blocks.length; address++) {
    final block = blocks[address]!;
    final slice = block.slice;
    if (slice.deblocking == 1) continue;
    final x = address % width;
    final row = address ~/ width;
    final start = (row * stride + x) * 16;
    final chromaStride = stride >> 1;
    final chromaStart = (row * chromaStride + x) * 8;
    final pps = slice.pps;
    for (final vertical in [true, false]) {
      final neighborAddress = vertical
          ? (x == 0 ? -1 : address - 1)
          : (row == 0 ? -1 : address - width);
      var neighbor = neighborAddress < 0 ? null : blocks[neighborAddress];
      if (slice.deblocking == 2 && neighbor?.slice != slice) neighbor = null;
      _edges(
        y,
        start,
        stride,
        vertical,
        16,
        block.transform8x8 ? 8 : 4,
        block.qp,
        neighbor?.qp,
        slice.alphaOffset,
        slice.betaOffset,
      );
      if (cb.isNotEmpty) {
        final cbQp = chromaQp(block.qp, pps.chromaOffset);
        final crQp = chromaQp(block.qp, pps.secondChromaOffset);
        _edges(
          cb,
          chromaStart,
          chromaStride,
          vertical,
          8,
          4,
          cbQp,
          neighbor == null ? null : chromaQp(neighbor.qp, pps.chromaOffset),
          slice.alphaOffset,
          slice.betaOffset,
        );
        _edges(
          cr,
          chromaStart,
          chromaStride,
          vertical,
          8,
          4,
          crQp,
          neighbor == null
              ? null
              : chromaQp(neighbor.qp, pps.secondChromaOffset),
          slice.alphaOffset,
          slice.betaOffset,
        );
      }
    }
  }
}

void _edges(
  Uint8List plane,
  int start,
  int stride,
  bool vertical,
  int width,
  int spacing,
  int qp,
  int? neighborQp,
  int alphaOffset,
  int betaOffset,
) {
  final across = vertical ? 1 : stride;
  final along = vertical ? stride : 1;
  for (
    var edge = neighborQp == null ? spacing : 0;
    edge < width;
    edge += spacing
  ) {
    final boundary = edge == 0;
    final averaged = boundary ? (qp + neighborQp! + 1) >> 1 : qp;
    final index = (averaged + alphaOffset).clamp(0, 51);
    final alpha = deblockAlpha[index];
    final beta = deblockBeta[(averaged + betaOffset).clamp(0, 51)];
    if (alpha == 0 || beta == 0) continue;
    final chroma = width == 8;
    final offset = start + edge * across;
    for (var i = 0; i < width; i++) {
      _filter(
        plane,
        offset + i * along,
        across,
        alpha,
        beta,
        deblockLimit[index],
        chroma: chroma,
        boundary: boundary,
      );
    }
  }
}

void _filter(
  Uint8List plane,
  int offset,
  int step,
  int alpha,
  int beta,
  int limit, {
  required bool chroma,
  required bool boundary,
}) {
  final p0 = plane[offset - step], p1 = plane[offset - 2 * step];
  final q0 = plane[offset], q1 = plane[offset + step];
  final gap = (p0 - q0).abs();
  if (gap >= alpha || (p1 - p0).abs() >= beta || (q1 - q0).abs() >= beta)
    return;

  if (boundary) {
    final strong = !chroma && gap < ((alpha >> 2) + 2);
    if (strong && (plane[offset - 3 * step] - p0).abs() < beta) {
      final p2 = plane[offset - 3 * step], p3 = plane[offset - 4 * step];
      plane[offset - step] = (p2 + 2 * p1 + 2 * p0 + 2 * q0 + q1 + 4) >> 3;
      plane[offset - 2 * step] = (p2 + p1 + p0 + q0 + 2) >> 2;
      plane[offset - 3 * step] = (2 * p3 + 3 * p2 + p1 + p0 + q0 + 4) >> 3;
    } else {
      plane[offset - step] = (2 * p1 + p0 + q1 + 2) >> 2;
    }
    if (strong && (plane[offset + 2 * step] - q0).abs() < beta) {
      final q2 = plane[offset + 2 * step], q3 = plane[offset + 3 * step];
      plane[offset] = (p1 + 2 * p0 + 2 * q0 + 2 * q1 + q2 + 4) >> 3;
      plane[offset + step] = (p0 + q0 + q1 + q2 + 2) >> 2;
      plane[offset + 2 * step] = (2 * q3 + 3 * q2 + q1 + q0 + p0 + 4) >> 3;
    } else {
      plane[offset] = (2 * q1 + q0 + p1 + 2) >> 2;
    }
    return;
  }

  var clip = limit;
  if (chroma) {
    clip++;
  } else {
    final p2 = plane[offset - 3 * step], q2 = plane[offset + 2 * step];
    final middle = (p0 + q0 + 1) >> 1;
    if ((p2 - p0).abs() < beta) {
      if (limit != 0) {
        plane[offset -
            2 * step] = (p1 + (((p2 + middle) >> 1) - p1).clamp(-limit, limit))
            .clamp(0, 255);
      }
      clip++;
    }
    if ((q2 - q0).abs() < beta) {
      if (limit != 0) {
        plane[offset +
            step] = (q1 + (((q2 + middle) >> 1) - q1).clamp(-limit, limit))
            .clamp(0, 255);
      }
      clip++;
    }
  }
  final delta = (((q0 - p0) * 4 + p1 - q1 + 4) >> 3).clamp(-clip, clip);
  plane[offset - step] = (p0 + delta).clamp(0, 255);
  plane[offset] = (q0 - delta).clamp(0, 255);
}
