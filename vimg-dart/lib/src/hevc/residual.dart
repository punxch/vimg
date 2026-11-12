import 'dart:math' as math;
import 'dart:typed_data';

import 'cabac.dart';
import 'contexts.dart';
import 'scan.dart';

/// HEVC §7.3.8.11, with coefficient positions returned in raster order.
final class HevcResidual {
  final _levels = Int32List(1024);
  final _coded = Uint8List(64);
  final _positions = Uint8List(16);
  final _magnitudes = Uint8List(16);
  final _signs = Uint8List(16);

  Int32List read(
    HevcCabac cabac,
    int log2,
    int mode, {
    required bool chroma,
    required bool hideSign,
  }) {
    final scan = log2 == 2 || (log2 == 3 && !chroma)
        ? (mode >= 6 && mode <= 14
              ? HevcScan.vertical
              : mode >= 22 && mode <= 30
              ? HevcScan.horizontal
              : HevcScan.diagonal)
        : HevcScan.diagonal;
    final size = 1 << log2, subSize = size >> 2;
    final scans = hevcScans[scan.index];
    final localScan = scans[2];
    final groupScan = scans[log2 - 2];
    final prefixX = _prefix(
      cabac,
      HevcContext.lastSigCoeffXPrefix,
      log2,
      chroma,
    );
    final prefixY = _prefix(
      cabac,
      HevcContext.lastSigCoeffYPrefix,
      log2,
      chroma,
    );
    final wireX = _last(cabac, prefixX), wireY = _last(cabac, prefixY);
    final (x, y) = scan == HevcScan.vertical ? (wireY, wireX) : (wireX, wireY);
    final lastGroup = groupScan.indexOf((y >> 2) * subSize + (x >> 2));
    final lastPosition = localScan.indexOf((y & 3) * 4 + (x & 3));
    if (lastGroup < 0 || lastPosition < 0)
      throw const FormatException('Invalid HEVC coefficient position');

    _levels.fillRange(0, size * size, 0);
    _coded.fillRange(0, subSize * subSize, 0);
    var greaterContext = 1;
    for (var group = lastGroup; group >= 0; group--) {
      final cell = groupScan[group];
      final sx = cell % subSize, sy = cell ~/ subSize;
      final right = sx + 1 < subSize ? _coded[cell + 1] : 0;
      final below = sy + 1 < subSize ? _coded[cell + subSize] : 0;
      var inferFirst = group != 0 && group != lastGroup;
      if (inferFirst &&
          cabac.decode(
                HevcContext.codedSubBlockFlag,
                (chroma ? 2 : 0) + (right + below > 0 ? 1 : 0),
              ) ==
              0)
        continue;
      _coded[cell] = 1;
      var count = 0;
      if (group == lastGroup) _positions[count++] = lastPosition;
      final start = group == lastGroup ? lastPosition - 1 : 15;
      for (var n = start; n >= 0; n--) {
        final position = localScan[n];
        final significant =
            n == 0 && inferFirst ||
            cabac.decode(
                  HevcContext.sigCoeffFlag,
                  _significantContext(
                    log2,
                    chroma,
                    scan,
                    cell == 0,
                    position,
                    right + 2 * below,
                  ),
                ) !=
                0;
        if (significant) {
          _positions[count++] = n;
          inferFirst = false;
        }
      }
      if (count == 0) continue;

      final contextSet =
          (chroma || group == 0 ? 0 : 2) + (greaterContext == 0 ? 1 : 0);
      greaterContext = 1;
      var firstGreater = -1;
      _magnitudes.fillRange(0, count, 1);
      for (var i = 0; i < math.min(count, 8); i++) {
        final greater = cabac.decode(
          HevcContext.coeffAbsLevelGreater1Flag,
          (chroma ? 16 : 0) + 4 * contextSet + greaterContext,
        );
        if (greater != 0) {
          greaterContext = 0;
          _magnitudes[i] = 2;
          if (firstGreater < 0) firstGreater = i;
        } else if (greaterContext > 0 && greaterContext < 3) {
          greaterContext++;
        }
      }
      if (firstGreater >= 0) {
        _magnitudes[firstGreater] += cabac.decode(
          HevcContext.coeffAbsLevelGreater2Flag,
          (chroma ? 4 : 0) + contextSet,
        );
      }
      final hidden = hideSign && _positions.first - _positions[count - 1] >= 4;
      final explicitSigns = count - (hidden ? 1 : 0);
      for (var i = 0; i < explicitSigns; i++) _signs[i] = cabac.bypass();
      var rice = 0, sum = 0;
      for (var i = 0; i < count; i++) {
        var magnitude = _magnitudes[i];
        final threshold = i >= 8
            ? 1
            : i == firstGreater
            ? 3
            : 2;
        if (magnitude == threshold) {
          magnitude += _remaining(cabac, rice);
          if (magnitude > 3 << rice && rice < 4) rice++;
        }
        if (magnitude > 32768)
          throw const FormatException('HEVC coefficient out of range');
        sum += magnitude;
        final sign = i == explicitSigns ? sum & 1 : _signs[i];
        final position = localScan[_positions[i]];
        _levels[(4 * sy + (position >> 2)) * size + 4 * sx + (position & 3)] =
            sign == 0 ? magnitude : -magnitude;
      }
    }
    return _levels;
  }
}

int _prefix(HevcCabac cabac, HevcContext context, int log2, bool chroma) {
  final offset = chroma ? 15 : 3 * (log2 - 2) + ((log2 - 1) >> 2);
  final shift = chroma ? log2 - 2 : (log2 + 1) >> 2;
  final maximum = 2 * log2 - 1;
  var prefix = 0;
  while (prefix < maximum &&
      cabac.decode(context, offset + (prefix >> shift)) != 0) {
    prefix++;
  }
  return prefix;
}

int _last(HevcCabac cabac, int prefix) {
  if (prefix <= 3) return prefix;
  final bits = (prefix >> 1) - 1;
  return ((2 + (prefix & 1)) << bits) + cabac.bypassBits(bits);
}

int _remaining(HevcCabac cabac, int rice) {
  var prefix = 0;
  while (prefix < 4 && cabac.bypass() != 0) prefix++;
  return (prefix << rice) +
      (prefix == 4 ? cabac.bypassGolomb(rice + 1) : cabac.bypassBits(rice));
}

int _significantContext(
  int log2,
  bool chroma,
  HevcScan scan,
  bool firstGroup,
  int position,
  int neighbors,
) {
  final offset = chroma ? 27 : 0;
  if (log2 == 2) return offset + _sig4[position];
  if (firstGroup && position == 0) return offset;
  final x = position & 3, y = position >> 2;
  final local = switch (neighbors) {
    0 =>
      x + y == 0
          ? 2
          : x + y < 3
          ? 1
          : 0,
    1 => math.max(0, 2 - y),
    2 => math.max(0, 2 - x),
    _ => 2,
  };
  if (chroma) return offset + local + (log2 == 3 ? 9 : 12);
  final base = log2 == 3 ? (scan == HevcScan.diagonal ? 9 : 15) : 21;
  return local + base + (firstGroup ? 0 : 3);
}

const _sig4 = [0, 1, 4, 5, 2, 3, 4, 5, 6, 6, 8, 8, 7, 7, 8, 8];
