import 'dart:io';
import 'dart:typed_data';

import 'package:vimg_dart/src/av1/bitstream.dart';
import 'package:vimg_dart/src/av1/coefficients.dart';
import 'package:vimg_dart/src/av1/quantizer.dart';
import 'package:vimg_dart/src/av1/range_decoder.dart';
import 'package:vimg_dart/src/av1/transform.dart';

import 'fixtures.dart';

void main() {
  _checkCoefficients();
  _checkQuantization();
}

// OxideAV's coefficient writer generated 114 consecutive transform blocks
// per base Q. Vectors include EOB refinement, 1D scans, Golomb escapes and
// varying top/left contexts. Hashes cover signed raster coefficients and EOB.
void _checkCoefficients() {
  const expected = 2026047759;
  for (final q in [12, 45, 87, 173]) {
    final data = File('test/fixtures/av1-coeff-$q.bin').readAsBytesSync();
    final range = RangeDecoder(Av1Bits(data));
    final states = List.generate(3, (_) => Av1CoefficientNeighbors(32, 32));
    var cdfs = Av1CoefficientCdfs(q);
    var decoder = Av1CoefficientDecoder(range, cdfs);
    final coefficients = Int32List(1024);
    var hash = 0;
    for (var i = 0; i < 114; i++) {
      if (i == 57) {
        cdfs = cdfs.copy();
        decoder = Av1CoefficientDecoder(range, cdfs);
      }
      final size = Av1TxSize.values[i % 19];
      final type = const [0, 1, 2, 5, 6, 7, 8, 13].contains(size.index)
          ? [Av1TxType.dctDct, Av1TxType.vDct, Av1TxType.hDct][i ~/ 19 % 3]
          : Av1TxType.dctDct;
      final plane = i ~/ 2 % 3;
      var typeReads = 0;
      final result = decoder.read(
        coefficients,
        neighbors: states[plane],
        x4: i * 3 % 24,
        y4: i * 5 % 24,
        blockWidth: i.isEven ? 64 : 128,
        blockHeight: i.isEven ? 64 : 128,
        size: size,
        chroma: plane != 0,
        readType: () {
          typeReads++;
          return type;
        },
      );
      check(
        i % 7 == 0
            ? result.eob == 0 &&
                  result.type == Av1TxType.dctDct &&
                  typeReads == 0
            : result.eob > 0 && result.type == type && typeReads == 1,
        'AV1 all-zero gate at block $i, Q $q',
      );
      hash = _hash(hash, result.eob);
      final count = size.coefficientWidth * size.coefficientHeight;
      for (var k = 0; k < count; k++) {
        hash = _hash(hash, coefficients[k] + 0x80000);
      }
    }
    range.finish();
    check(hash == expected, 'AV1 signed coefficient raster at Q $q: $hash');
  }
}

void _checkQuantization() {
  // OxideAV dequantization checksums over all transform sizes, bit depths,
  // planes and matrix levels, including delta-Q and segmentation.
  const expected = {8: 543077524, 10: 807506099, 12: 725226612};
  for (final entry in expected.entries) {
    final depth = entry.key;
    var hash = 0;
    final buffer = Int32List(1024);
    for (final size in Av1TxSize.values) {
      final count = size.coefficientWidth * size.coefficientHeight;
      for (var level = 0; level < 16; level++) {
        final q = Av1Quantizer((
          base: 74,
          yDc: -3,
          uDc: 4,
          uAc: 5,
          vDc: -12,
          vAc: 24,
          matrix: (level, level, level),
        ), depth);
        for (var plane = 0; plane < 3; plane++) {
          for (final type in [Av1TxType.dctDct, Av1TxType.identity]) {
            for (var i = 0; i < count; i++) {
              buffer[i] = i % 7 == 0 ? i * 159 % 50000 - 10000 : 0;
            }
            q.apply(
              buffer,
              size,
              type,
              plane,
              currentQ: 31 + level * 9,
              segmentDelta: level * 4 - 33,
            );
            for (var i = 0; i < count; i++) {
              hash = _hash(hash, buffer[i] + 0x80000);
            }
          }
        }
      }
    }
    check(hash == entry.value, 'AV1 dequantization at $depth bits: $hash');
  }
}

int _hash(int hash, int value) => (hash * 257 + value) & 0x7fffffff;
