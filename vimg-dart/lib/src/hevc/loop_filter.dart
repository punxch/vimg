import 'dart:math' as math;
import 'dart:typed_data';

import 'ctu_layout.dart';
import 'picture.dart';
import 'sao.dart';
import 'slice_header.dart';
import 'transform.dart';

/// Apply the HEVC in-loop filters in picture order (§8.7).
final class HevcLoopFilter {
  HevcLoopFilter(
    this.picture,
    this.layout,
    this.owners,
    this.headers,
    this.qp,
    this.edges,
    this.disabled,
    this.sao,
  );

  final HevcPicture picture;
  final HevcCtuLayout layout;
  final Int32List owners;
  final List<HevcSliceHeader?> headers;
  final Int8List qp;
  final Uint8List edges, disabled;
  final List<HevcSao> sao;

  int _cell(int x, int y) => (y >> 2) * (picture.luma.width >> 2) + (x >> 2);

  bool _across(int a, int b) {
    if (a == b) return true;
    if (layout.tile[a] != layout.tile[b] &&
        headers[a]!.pps.tiles?.filterAcross == false)
      return false;
    final later = layout.index[a] > layout.index[b] ? a : b;
    return owners[a] == owners[b] ||
        headers[later]!.parameters.filterAcrossSlices;
  }

  void apply() {
    _deblock(true);
    _deblock(false);
    _offset(picture.luma, 0);
    if (picture.cb != null) {
      _offset(picture.cb!, 1);
      _offset(picture.cr!, 2);
    }
  }

  void _deblock(bool vertical) {
    final flag = vertical ? 1 : 2;
    final luma = picture.luma;
    for (var y = 0; y < luma.height; y += vertical ? 4 : 8) {
      for (var x = 0; x < luma.width; x += vertical ? 8 : 4) {
        final qCell = _cell(x, y);
        if (edges[qCell] & flag == 0) continue;
        final px = x - (vertical ? 1 : 0), py = y - (vertical ? 0 : 1);
        final qCtu = layout.atSample(x, y), pCtu = layout.atSample(px, py);
        final header = headers[qCtu]!;
        final parameters = header.parameters;
        if (parameters.deblockDisabled || !_across(qCtu, pCtu)) continue;
        final pCell = _cell(px, py);
        final keepP = disabled[pCell] != 0, keepQ = disabled[qCell] != 0;
        if (keepP && keepQ) continue;
        final average = (qp[pCell] + qp[qCell] + 1) >> 1;
        // All reconstructed edges here adjoin an intra CU (bS = 2).
        final beta =
            _beta[(average + parameters.beta).clamp(0, 51)] << (luma.depth - 8);
        final tc =
            _tc[(average + 2 + parameters.tc).clamp(0, 53)] << (luma.depth - 8);
        if (beta > 0 && tc > 0)
          _luma(luma, x, y, vertical, beta, tc, keepP, keepQ);
        if (picture.cb == null ||
            (vertical ? x : y) & 15 != 0 ||
            (vertical ? y : x) & 7 != 0)
          continue;
        final offsets = header.pps.chromaOffsets;
        _chroma(
          picture.cb!,
          x >> 1,
          y >> 1,
          vertical,
          average + offsets.cb,
          parameters.tc,
          keepP,
          keepQ,
        );
        _chroma(
          picture.cr!,
          x >> 1,
          y >> 1,
          vertical,
          average + offsets.cr,
          parameters.tc,
          keepP,
          keepQ,
        );
      }
    }
  }

  void _offset(HevcPlane plane, int component) {
    if (sao.every((entry) => entry[component].type == 0)) return;
    final source = Uint16List.fromList(plane.samples);
    final shift = component == 0 ? 0 : 1;
    final log2 = picture.sps.ctbLog2 - shift;
    final size = 1 << log2;
    final columns = picture.sps.ctbWidth;
    for (var address = 0; address < sao.length; address++) {
      final filter = sao[address][component];
      if (filter.type == 0) continue;
      final x0 = (address % columns) << log2, y0 = (address ~/ columns) << log2;
      final endX = math.min(plane.width, x0 + size),
          endY = math.min(plane.height, y0 + size);
      final (dx, dy) = _edgeDirections[filter.type == 2 ? filter.position : 0];
      for (var y = y0; y < endY; y++) {
        for (var x = x0; x < endX; x++) {
          if (disabled[_cell(x << shift, y << shift)] != 0) continue;
          final index = y * plane.width + x;
          final current = source[index];
          final int category;
          if (filter.type == 1) {
            category = ((current >> (plane.depth - 5)) - filter.position) & 31;
            if (category >= 4) continue;
          } else {
            final ax = x - dx, ay = y - dy, bx = x + dx, by = y + dy;
            if (!plane.contains(ax, ay) || !plane.contains(bx, by)) continue;
            if (!_across(address, layout.atSample(ax << shift, ay << shift)) ||
                !_across(address, layout.atSample(bx << shift, by << shift)))
              continue;
            final first = source[ay * plane.width + ax];
            final second = source[by * plane.width + bx];
            final edge = current.compareTo(first) + current.compareTo(second);
            if (edge == 0) continue;
            category = edge < 0 ? edge + 2 : edge + 1;
          }
          plane.samples[index] = (current + filter.offsets[category]).clamp(
            0,
            plane.maximum,
          );
        }
      }
    }
  }
}

void _luma(
  HevcPlane plane,
  int x,
  int y,
  bool vertical,
  int beta,
  int tc,
  bool keepP,
  bool keepQ,
) {
  final across = vertical ? 1 : plane.width;
  final along = vertical ? plane.width : 1;
  final length = math.min(4, vertical ? plane.height - y : plane.width - x);
  final origin = y * plane.width + x;
  final end = origin + (length - 1) * along;
  final samples = plane.samples;

  int curvature(int index, int step) =>
      (samples[index + 2 * step] - 2 * samples[index + step] + samples[index])
          .abs();
  final p0 = curvature(origin - across, -across),
      p3 = curvature(end - across, -across);
  final q0 = curvature(origin, across), q3 = curvature(end, across);
  if (p0 + p3 + q0 + q3 >= beta) return;

  bool strong(int index, int curvature) =>
      2 * curvature < beta >> 2 &&
      (samples[index - 4 * across] - samples[index - across]).abs() +
              (samples[index] - samples[index + 3 * across]).abs() <
          beta >> 3 &&
      (samples[index - across] - samples[index]).abs() < (5 * tc + 1) >> 1;
  final long = strong(origin, p0 + q0) && strong(end, p3 + q3);
  final threshold = (beta + (beta >> 1)) >> 3;
  final extraP = p0 + p3 < threshold, extraQ = q0 + q3 < threshold;
  for (var i = 0; i < length; i++) {
    final edge = origin + i * along;
    final p = edge - across;
    final p0 = samples[p],
        p1 = samples[p - across],
        p2 = samples[p - 2 * across];
    final q0 = samples[edge],
        q1 = samples[edge + across],
        q2 = samples[edge + 2 * across];
    if (long) {
      final p3 = samples[p - 3 * across], q3 = samples[edge + 3 * across];
      final limit = 2 * tc;
      if (!keepP) {
        samples[p] = ((p2 + 2 * p1 + 2 * p0 + 2 * q0 + q1 + 4) >> 3).clamp(
          p0 - limit,
          p0 + limit,
        );
        samples[p - across] = ((p2 + p1 + p0 + q0 + 2) >> 2).clamp(
          p1 - limit,
          p1 + limit,
        );
        samples[p - 2 * across] = ((2 * p3 + 3 * p2 + p1 + p0 + q0 + 4) >> 3)
            .clamp(p2 - limit, p2 + limit);
      }
      if (!keepQ) {
        samples[edge] = ((p1 + 2 * p0 + 2 * q0 + 2 * q1 + q2 + 4) >> 3).clamp(
          q0 - limit,
          q0 + limit,
        );
        samples[edge + across] = ((p0 + q0 + q1 + q2 + 2) >> 2).clamp(
          q1 - limit,
          q1 + limit,
        );
        samples[edge + 2 * across] = ((p0 + q0 + q1 + 3 * q2 + 2 * q3 + 4) >> 3)
            .clamp(q2 - limit, q2 + limit);
      }
      continue;
    }
    final change = (9 * (q0 - p0) - 3 * (q1 - p1) + 8) >> 4;
    if (change.abs() >= 10 * tc) continue;
    final delta = change.clamp(-tc, tc), half = tc >> 1;
    if (!keepP) {
      samples[p] = (p0 + delta).clamp(0, plane.maximum);
      if (extraP) {
        final second = ((((p2 + p0 + 1) >> 1) - p1 + delta) >> 1).clamp(
          -half,
          half,
        );
        samples[p - across] = (p1 + second).clamp(0, plane.maximum);
      }
    }
    if (!keepQ) {
      samples[edge] = (q0 - delta).clamp(0, plane.maximum);
      if (extraQ) {
        final second = ((((q2 + q0 + 1) >> 1) - q1 - delta) >> 1).clamp(
          -half,
          half,
        );
        samples[edge + across] = (q1 + second).clamp(0, plane.maximum);
      }
    }
  }
}

void _chroma(
  HevcPlane plane,
  int x,
  int y,
  bool vertical,
  int qp,
  int tcOffset,
  bool keepP,
  bool keepQ,
) {
  final tc =
      _tc[(hevcChromaQp420(qp) + 2 + tcOffset).clamp(0, 53)] <<
      (plane.depth - 8);
  if (tc == 0) return;
  final across = vertical ? 1 : plane.width;
  final along = vertical ? plane.width : 1;
  final count = math.min(4, vertical ? plane.height - y : plane.width - x);
  final samples = plane.samples;
  var edge = y * plane.width + x;
  for (var i = 0; i < count; i++, edge += along) {
    final p = edge - across;
    final p0 = samples[p], q0 = samples[edge];
    final delta =
        ((4 * (q0 - p0) + samples[p - across] - samples[edge + across] + 4) >>
                3)
            .clamp(-tc, tc);
    if (!keepP) samples[p] = (p0 + delta).clamp(0, plane.maximum);
    if (!keepQ) samples[edge] = (q0 - delta).clamp(0, plane.maximum);
  }
}

const _edgeDirections = [(1, 0), (0, 1), (1, 1), (-1, 1)];

// H.265 Table 8-12.
// dart format off
const _beta = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 20, 22, 24,
  26, 28, 30, 32, 34, 36, 38, 40, 42, 44, 46, 48, 50, 52, 54, 56,
  58, 60, 62, 64];
const _tc = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
  1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4,
  5, 5, 6, 6, 7, 8, 9, 10, 11, 13, 14, 16, 18, 20, 22, 24];
