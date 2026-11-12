import 'dart:math' as math;
import 'dart:typed_data';

import 'coefficient_cdfs.dart';
import 'range_decoder.dart';
import 'transform.dart';

enum _Family { skip, eobPoint, eobExtra, baseEob, base, baseRange, dcSign }

/// Coefficient probabilities initialized from the frame's base Q index.
/// A saved copy can be reused through primary_ref_frame in a later frame.
final class Av1CoefficientCdfs {
  Av1CoefficientCdfs(int baseQ)
    : _qContext = baseQ <= 20
          ? 0
          : baseQ <= 60
          ? 1
          : baseQ <= 120
          ? 2
          : 3,
      _adapted = {};

  Av1CoefficientCdfs._(this._qContext, this._adapted);

  final int _qContext;
  final Map<(_Family, int, int, int), Av1Cdf> _adapted;

  Av1CoefficientCdfs copy({bool resetCount = false}) =>
      Av1CoefficientCdfs._(_qContext, {
        for (final entry in _adapted.entries)
          entry.key: entry.value.copy(resetCount: resetCount),
      });

  Av1Cdf _table(_Family family, int size, int plane, int context) =>
      _adapted.putIfAbsent((family, size, plane, context), () {
        final q = _qContext;
        return Av1Cdf(switch (family) {
          _Family.skip => av1TxbSkipCdfs[q][size][context],
          _Family.eobPoint => av1EobPointCdfs[size][q][plane][context],
          _Family.eobExtra => av1EobExtraCdfs[q][size][plane][context],
          _Family.baseEob => av1BaseEobCdfs[q][size][plane][context],
          _Family.base => av1BaseCdfs[q][size][plane][context],
          _Family.baseRange => av1BaseRangeCdfs[q][size][plane][context],
          _Family.dcSign => av1DcSignCdfs[q][plane][context],
        });
      });
}

/// The entropy state at the top and left of one tile's sample plane.
/// Coordinates and extents are in 4×4 units relative to the tile.
final class Av1CoefficientNeighbors {
  Av1CoefficientNeighbors(int columns, int rows)
    : _above = Uint8List(columns),
      _left = Uint8List(rows);

  final Uint8List _above, _left;

  void stamp(int x4, int y4, int width4, int height4, int level, int dcSign) {
    final state =
        level |
        ((dcSign < 0
                ? 1
                : dcSign > 0
                ? 2
                : 0) <<
            6);
    _above.fillRange(x4, math.min(x4 + width4, _above.length), state);
    _left.fillRange(y4, math.min(y4 + height4, _left.length), state);
  }

  ({int skip, int dcSign}) _contexts(
    int x4,
    int y4,
    Av1TxSize size,
    int blockWidth,
    int blockHeight,
    bool chroma,
  ) {
    var top = 0, left = 0, sign = 0;
    final mask = chroma ? 255 : 63;
    final xEnd = math.min(x4 + (size.width >> 2), _above.length);
    final yEnd = math.min(y4 + (size.height >> 2), _left.length);
    const signByCategory = [0, -1, 1];
    for (var x = x4; x < xEnd; x++) {
      final state = _above[x];
      top = math.max(top, state & mask);
      sign += signByCategory[state >> 6];
    }
    for (var y = y4; y < yEnd; y++) {
      final state = _left[y];
      left = math.max(left, state & mask);
      sign += signByCategory[state >> 6];
    }
    final int skip;
    if (chroma) {
      skip =
          7 +
          (top == 0 ? 0 : 1) +
          (left == 0 ? 0 : 1) +
          (blockWidth * blockHeight > size.width * size.height ? 3 : 0);
    } else if (blockWidth == size.width && blockHeight == size.height) {
      skip = 0;
    } else {
      final low = math.min(top, left), high = math.max(top, left);
      skip = low == 0
          ? high == 0
                ? 1
                : high <= 3
                ? 2
                : 3
          : high <= 3
          ? 4
          : low <= 3
          ? 5
          : 6;
    }
    return (
      skip: skip,
      dcSign: sign == 0
          ? 0
          : sign < 0
          ? 1
          : 2,
    );
  }
}

/// AV1 §5.11.39. Reads signed quantized coefficients in a compact raster.
final class Av1CoefficientDecoder {
  Av1CoefficientDecoder(this._reader, this._cdfs);

  final RangeDecoder _reader;
  final Av1CoefficientCdfs _cdfs;
  final _levels = Uint8List(36 * 36);

  /// Calls [readType] at the point where the luma transform type is coded.
  /// For chroma it returns the transform derived from already decoded syntax.
  ({Av1TxType type, int eob}) read(
    Int32List quantized, {
    required Av1CoefficientNeighbors neighbors,
    required int x4,
    required int y4,
    required int blockWidth,
    required int blockHeight,
    required Av1TxSize size,
    required bool chroma,
    required Av1TxType Function() readType,
  }) {
    final width = size.coefficientWidth, height = size.coefficientHeight;
    final count = width * height;
    final sizeContext = size.coefficientContext;
    final plane = chroma ? 1 : 0;
    final context = neighbors._contexts(
      x4,
      y4,
      size,
      blockWidth,
      blockHeight,
      chroma,
    );
    quantized.fillRange(0, count, 0);
    if (_symbol(_Family.skip, sizeContext, 0, context.skip) != 0) {
      neighbors.stamp(x4, y4, size.width >> 2, size.height >> 2, 0, 0);
      return (type: Av1TxType.dctDct, eob: 0);
    }

    final type = readType();
    final txClass = type.txClass;
    final eob = _readEob(count, sizeContext, plane, txClass);
    final scan = _scans[(width, height, txClass)]!;
    final stride = width + 4;
    _levels.fillRange(0, (height + 4) * stride, 0);
    final offsets = switch (txClass) {
      Av1TxClass.twoDimensional => (stride + 1, 2, 2 * stride),
      Av1TxClass.horizontal => (2, 3, 4),
      Av1TxClass.vertical => (2 * stride, 3 * stride, 4 * stride),
    };
    final brSize = math.min(sizeContext, 3);
    for (var i = eob - 1; i >= 0; i--) {
      final pos = scan[i];
      final row = pos ~/ width, col = pos % width;
      final p = row * stride + col;
      final first = _levels[p + 1], second = _levels[p + stride];
      final third = _levels[p + offsets.$1];
      final int base;
      if (i == eob - 1) {
        final context = i == 0
            ? 0
            : i <= count >> 3
            ? 1
            : i <= count >> 2
            ? 2
            : 3;
        base = 1 + _symbol(_Family.baseEob, sizeContext, plane, context);
      } else {
        final sum =
            math.min<int>(first, 3) +
            math.min<int>(second, 3) +
            math.min<int>(third, 3) +
            math.min<int>(_levels[p + offsets.$2], 3) +
            math.min<int>(_levels[p + offsets.$3], 3);
        final offset = _baseOffset(size, txClass, row, col);
        final context = offset == 0
            ? 0
            : offset + math.min<int>((sum + 1) >> 1, 4);
        base = _symbol(_Family.base, sizeContext, plane, context);
      }

      var level = base;
      if (level == 3) {
        final nearby = switch (txClass) {
          Av1TxClass.twoDimensional => row < 2 && col < 2,
          Av1TxClass.horizontal => col == 0,
          Av1TxClass.vertical => row == 0,
        };
        final context =
            math.min((first + second + third + 1) >> 1, 6) +
            (pos == 0
                ? 0
                : nearby
                ? 7
                : 14);
        final table = _cdfs._table(_Family.baseRange, brSize, plane, context);
        for (var k = 0; k < 4; k++) {
          final increment = _reader.adaptive(table);
          level += increment;
          if (increment < 3) break;
        }
      }
      _levels[p] = level;
      quantized[pos] = level;
    }

    var cumulative = 0, dcSign = 0;
    for (var i = 0; i < eob; i++) {
      final pos = scan[i];
      var level = quantized[pos];
      if (level == 0) continue;
      final negative =
          (i == 0
              ? _symbol(_Family.dcSign, 0, plane, context.dcSign)
              : _reader.literal(1)) !=
          0;
      if (level == 15) level = _readGolomb() + 14;
      if (pos == 0) dcSign = negative ? -1 : 1;
      level &= 0xfffff;
      cumulative += level;
      quantized[pos] = negative ? -level : level;
    }
    neighbors.stamp(
      x4,
      y4,
      size.width >> 2,
      size.height >> 2,
      math.min(cumulative, 63),
      dcSign,
    );
    return (type: type, eob: eob);
  }

  int _symbol(_Family family, int size, int plane, int context) =>
      _reader.adaptive(_cdfs._table(family, size, plane, context));

  int _readEob(int count, int sizeContext, int plane, Av1TxClass txClass) {
    final multi = count.bitLength - 5;
    final context = multi < 5 && txClass != Av1TxClass.twoDimensional ? 1 : 0;
    final point = 1 + _symbol(_Family.eobPoint, multi, plane, context);
    if (point == 1) return 1;
    final start = (1 << (point - 2)) + 1;
    final shift = point - 3;
    if (shift < 0) return start;
    final high = _symbol(_Family.eobExtra, sizeContext, plane, shift);
    return start + (high << shift) + _reader.literal(shift);
  }

  int _readGolomb() {
    var zeros = 0;
    while (_reader.literal(1) == 0) {
      if (++zeros >= 20) {
        throw const FormatException('Invalid AV1 coefficient Golomb code');
      }
    }
    return (1 << zeros) + _reader.literal(zeros);
  }
}

int _baseOffset(Av1TxSize size, Av1TxClass txClass, int row, int col) {
  if (txClass != Av1TxClass.twoDimensional) {
    final axis = txClass == Av1TxClass.horizontal ? col : row;
    return 26 + 5 * math.min(axis, 2);
  }
  final diagonal = row + col;
  if (diagonal == 0) return 0;
  if (size.height > size.width && row < 2) return 11;
  if (size.width > size.height && col < 2) return 16;
  if (diagonal < 2) return 1;
  return diagonal < 4 ? 6 : 21;
}

final _scans = <(int, int, Av1TxClass), Uint16List>{
  for (final (w, h) in {
    for (final size in Av1TxSize.values)
      (size.coefficientWidth, size.coefficientHeight),
  })
    for (final txClass in Av1TxClass.values)
      (w, h, txClass): _buildScan(w, h, txClass),
};

Uint16List _buildScan(int width, int height, Av1TxClass txClass) {
  final scan = Uint16List(width * height);
  switch (txClass) {
    case Av1TxClass.horizontal:
      for (var x = 0, i = 0; x < width; x++) {
        for (var y = 0; y < height; y++) {
          scan[i++] = y * width + x;
        }
      }
    case Av1TxClass.vertical:
      for (var i = 0; i < scan.length; i++) {
        scan[i] = i;
      }
    case Av1TxClass.twoDimensional:
      for (var d = 0, i = 0; d < width + height - 1; d++) {
        final lo = math.max(0, d - height + 1), hi = math.min(d, width - 1);
        final descending = width < height || (width == height && d.isOdd);
        for (var k = 0; k <= hi - lo; k++) {
          final x = descending ? hi - k : lo + k;
          scan[i++] = (d - x) * width + x;
        }
      }
  }
  return scan;
}
