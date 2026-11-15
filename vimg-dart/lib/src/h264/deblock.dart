import 'deblock_tables.dart';
import 'mbaff.dart';
import 'motion.dart';
import 'picture.dart';
import 'slice_data.dart';
import 'transforms.dart';

/// H.264 deblocking (§8.7) in macroblock order. Inter edges use per-4×4
/// residual and reference information to choose the boundary strength.
void deblockPicture(List<Macroblock?> blocks, H264Picture picture) {
  final sps = picture.sps;
  if (blocks.first!.slice.mbaff) {
    _deblockMbaff(MbaffLayout(blocks, sps.mbWidth), picture);
    return;
  }
  final width = sps.mbWidth, stride = picture.stride;
  final chromaQpOffset = sps.chromaQpOffset;
  final motion = picture.motionL0, motion1 = picture.motionL1;
  final cb = picture.cb, cr = picture.cr;
  for (var address = 0; address < blocks.length; address++) {
    final block = blocks[address]!;
    final slice = block.slice;
    if (slice.deblocking == 1) continue;
    final x = address % width;
    final row = address ~/ width;
    final start = (row * stride + x) * 16;
    final chromaStride = picture.chromaStride;
    final chromaStart =
        row * chromaStride * sps.chromaHeight + x * sps.chromaWidth;
    final pps = slice.pps;
    for (final vertical in [true, false]) {
      final neighborAddress = vertical
          ? (x == 0 ? -1 : address - 1)
          : (row == 0 ? -1 : address - width);
      var neighbor = neighborAddress < 0 ? null : blocks[neighborAddress];
      if (slice.deblocking == 2 && neighbor?.slice != slice) neighbor = null;

      int strength(int edge, int segment) => _strength(
        block,
        neighbor,
        motion,
        motion1,
        x,
        row,
        vertical,
        edge,
        segment,
      );
      _edges(
        picture.y,
        start,
        stride,
        vertical,
        16,
        16,
        sps.lumaDepth,
        block.transform8x8 ? 8 : 4,
        block.qp,
        neighbor?.qp,
        slice.alphaOffset,
        slice.betaOffset,
        strength,
      );
      if (cb.isNotEmpty) {
        final chromaSpacing = sps.fullChroma && block.transform8x8 ? 8 : 4;
        final cbQp = chromaQp(block.qp, pps.chromaOffset, chromaQpOffset);
        final crQp = chromaQp(block.qp, pps.secondChromaOffset, chromaQpOffset);
        _edges(
          cb,
          chromaStart,
          chromaStride,
          vertical,
          sps.chromaWidth,
          sps.chromaHeight,
          sps.chromaDepth,
          chromaSpacing,
          cbQp,
          neighbor == null
              ? null
              : chromaQp(neighbor.qp, pps.chromaOffset, chromaQpOffset),
          slice.alphaOffset,
          slice.betaOffset,
          strength,
        );
        _edges(
          cr,
          chromaStart,
          chromaStride,
          vertical,
          sps.chromaWidth,
          sps.chromaHeight,
          sps.chromaDepth,
          chromaSpacing,
          crQp,
          neighbor == null
              ? null
              : chromaQp(neighbor.qp, pps.secondChromaOffset, chromaQpOffset),
          slice.alphaOffset,
          slice.betaOffset,
          strength,
        );
      }
    }
  }
}

void _deblockMbaff(MbaffLayout layout, H264Picture picture) {
  final sps = picture.sps;
  final planes = [picture.y, picture.cb, picture.cr];
  final motion = picture.motionL0, motion1 = picture.motionL1;
  for (var address = 0; address < layout.blocks.length; address++) {
    final block = layout.blocks[address]!;
    final slice = block.slice;
    if (slice.deblocking == 1) continue;
    final field = block.mbaffField;
    final column = layout.column(address), row = layout.row(address);
    int strength(
      Macroblock other,
      int otherAddress,
      int x,
      int y,
      int px,
      int py,
      int intraStrength,
    ) {
      if (block.intra || other.intra) return intraStrength;
      return _interStrength(
        block,
        other,
        motion!,
        motion1,
        column * 4 + x,
        row * 4 + y,
        layout.column(otherAddress) * 4 + px,
        layout.row(otherAddress) * 4 + py,
      );
    }

    for (var component = 0; component < planes.length; component++) {
      final plane = planes[component];
      if (plane.isEmpty) continue;
      final luma = component == 0;
      final width = luma ? 16 : sps.chromaWidth;
      final height = luma ? 16 : sps.chromaHeight;
      final depth = luma ? sps.lumaDepth : sps.chromaDepth;
      final stride = luma ? picture.stride : picture.chromaStride;
      final step = field ? 2 * stride : stride;
      final start =
          MbaffLayout.firstRow(row, height, field) * stride + column * width;
      final spacing = width == 16 && block.transform8x8 ? 8 : 4;
      final chromaOffset = component == 1
          ? slice.pps.chromaOffset
          : slice.pps.secondChromaOffset;
      int qp(Macroblock other) => luma
          ? other.qp
          : chromaQp(other.qp, chromaOffset, sps.chromaQpOffset);
      final currentQp = qp(block);
      Macroblock? neighbor(int x, int y) {
        final other = layout
            .neighbor(address, field, x, y, width, height)
            .block;
        return slice.deblocking == 2 && other?.slice != slice ? null : other;
      }

      void boundary(
        Macroblock other,
        int offset,
        int across,
        int along,
        int count,
        int Function(int) strengthAt,
      ) {
        final shift = depth - 8;
        final average = (currentQp + qp(other) + 1) >> 1;
        final index = (average + slice.alphaOffset).clamp(0, 51);
        final alpha = deblockAlpha[index] << shift;
        final beta =
            deblockBeta[(average + slice.betaOffset).clamp(0, 51)] << shift;
        if (alpha == 0 || beta == 0) return;
        for (var i = 0; i < count; i++) {
          final strength = strengthAt(i);
          if (strength == 0) continue;
          final limit = strength == 4
              ? 0
              : deblockLimit[strength - 1][index] << shift;
          _filter(
            plane,
            offset + i * along,
            across,
            alpha,
            beta,
            limit,
            (1 << depth) - 1,
            chroma: width == 8,
            boundary: strength == 4,
          );
        }
      }

      void interior(bool vertical) {
        _edges(
          plane,
          start,
          step,
          vertical,
          width,
          height,
          depth,
          spacing,
          currentQp,
          null,
          slice.alphaOffset,
          slice.betaOffset,
          (edge, segment) {
            final x = vertical ? edge : segment;
            final y = vertical ? segment : edge;
            return strength(
              block,
              address,
              x,
              y,
              x - (vertical ? 1 : 0),
              y - (vertical ? 0 : 1),
              3,
            );
          },
        );
      }

      for (var y = 0; y < height; y++) {
        final left = neighbor(-1, y);
        if (left == null) continue;
        // Chroma 4:2:0 uses the corresponding luma strength of the same field.
        final line = height == 16
            ? y
            : (field && !left.mbaffField)
            ? 2 * y
            : (y & ~1) * 2 + (y & 1);
        final at = layout.neighbor(address, field, -1, line, 16, 16);
        boundary(left, start + y * step, 1, step, 1, (_) {
          return strength(at.block!, at.address, 0, line ~/ 4, 3, at.y ~/ 4, 4);
        });
      }
      interior(true);

      void horizontal(
        Macroblock other,
        int sampleRow,
        int offset,
        int across,
        int intraStrength,
      ) {
        final at = layout.neighbor(address, field, 0, sampleRow, 16, 16);
        boundary(other, offset, across, 1, width, (i) {
          final x = i * 4 ~/ width;
          return strength(
            at.block!,
            at.address,
            x,
            0,
            x,
            at.y ~/ 4,
            intraStrength,
          );
        });
      }

      final top = neighbor(0, -1);
      if (top != null) {
        if (!field && top.mbaffField) {
          // A frame below two fields has a separate boundary for each parity.
          final evenTop = neighbor(0, -2);
          if (evenTop != null) horizontal(evenTop, -2, start, 2 * stride, 3);
          horizontal(top, -1, start + stride, 2 * stride, 3);
        } else {
          horizontal(top, -1, start, step, field ? 3 : 4);
        }
      }
      interior(false);
    }
  }
}

int _strength(
  Macroblock block,
  Macroblock? neighbor,
  MotionField? motion,
  MotionField? motion1,
  int mbX,
  int mbY,
  bool vertical,
  int edge,
  int segment,
) {
  final other = edge == 0 ? neighbor! : block;
  final field = block.slice.field;
  if (block.intra || other.intra) {
    return edge == 0 && (!field || vertical) ? 4 : 3;
  }
  final x = mbX * 4 + (vertical ? edge : segment);
  final y = mbY * 4 + (vertical ? segment : edge);
  final px = x - (vertical ? 1 : 0);
  final py = y - (vertical ? 0 : 1);
  return _interStrength(block, other, motion!, motion1, x, y, px, py);
}

int _interStrength(
  Macroblock block,
  Macroblock other,
  MotionField motion,
  MotionField? motion1,
  int x,
  int y,
  int px,
  int py,
) {
  if (block.codedLuma & (1 << blockIndex(x & 3, y & 3)) != 0 ||
      other.codedLuma & (1 << blockIndex(px & 3, py & 3)) != 0) {
    return 2;
  }
  if (block.mbaffField != other.mbaffField) return 1;
  bool same(MotionField first, MotionField second) {
    if (first.identityAt(px, py) != second.identityAt(x, y)) return false;
    final a = first.vectorAt(px, py);
    final b = second.vectorAt(x, y);
    return (a.x - b.x).abs() < 4 && (a.y - b.y).abs() < (block.field ? 2 : 4);
  }

  final primary = same(motion, motion);
  if (motion1 == null) return primary ? 0 : 1;
  return (primary && same(motion1, motion1)) ||
          (same(motion, motion1) && same(motion1, motion))
      ? 0
      : 1;
}

void _edges(
  List<int> plane,
  int start,
  int stride,
  bool vertical,
  int width,
  int height,
  int depth,
  int spacing,
  int qp,
  int? neighborQp,
  int alphaOffset,
  int betaOffset,
  int Function(int edge, int segment) strengthAt,
) {
  final across = vertical ? 1 : stride;
  final along = vertical ? stride : 1;
  final chroma = width == 8;
  final shift = depth - 8;
  final maximum = (1 << depth) - 1;
  final extent = vertical ? width : height;
  final segmentWidth = (vertical ? height : width) ~/ 4;
  for (
    var edge = neighborQp == null ? spacing : 0;
    edge < extent;
    edge += spacing
  ) {
    final averaged = edge == 0 ? (qp + neighborQp! + 1) >> 1 : qp;
    final index = (averaged + alphaOffset).clamp(0, 51);
    final alpha = deblockAlpha[index] << shift;
    final beta = deblockBeta[(averaged + betaOffset).clamp(0, 51)] << shift;
    if (alpha == 0 || beta == 0) continue;
    for (var segment = 0; segment < 4; segment++) {
      final strength = strengthAt(edge * 4 ~/ extent, segment);
      if (strength == 0) continue;
      final limit = strength == 4
          ? 0
          : deblockLimit[strength - 1][index] << shift;
      final offset = start + edge * across + segment * segmentWidth * along;
      for (var i = 0; i < segmentWidth; i++) {
        _filter(
          plane,
          offset + i * along,
          across,
          alpha,
          beta,
          limit,
          maximum,
          chroma: chroma,
          boundary: strength == 4,
        );
      }
    }
  }
}

void _filter(
  List<int> plane,
  int offset,
  int step,
  int alpha,
  int beta,
  int limit,
  int maximum, {
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
            .clamp(0, maximum);
      }
      clip++;
    }
    if ((q2 - q0).abs() < beta) {
      if (limit != 0) {
        plane[offset +
            step] = (q1 + (((q2 + middle) >> 1) - q1).clamp(-limit, limit))
            .clamp(0, maximum);
      }
      clip++;
    }
  }
  final delta = (((q0 - p0) * 4 + p1 - q1 + 4) >> 3).clamp(-clip, clip);
  plane[offset - step] = (p0 + delta).clamp(0, maximum);
  plane[offset] = (q0 - delta).clamp(0, maximum);
}
