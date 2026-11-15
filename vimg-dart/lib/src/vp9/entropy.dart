import 'dart:math' as math;
import 'dart:typed_data';

import 'bitstream.dart';
import 'tables.dart';

/// The Boolean arithmetic decoder restarts at each compressed partition.
final class Vp9BoolReader {
  Vp9BoolReader(this._bytes, int offset, int length)
    : _position = (offset + 1) * 8,
      _end = (offset + length) * 8,
      _value = _bytes[offset] {
    if (bit(128) != 0) {
      throw const FormatException('Nonzero VP9 arithmetic partition marker');
    }
  }

  final Uint8List _bytes;
  int _position;
  final int _end;
  int _value;
  int _range = 255;

  int bit(int probability) {
    final split = 1 + (((_range - 1) * probability) >> 8);
    final one = _value >= split;
    if (one) {
      _range -= split;
      _value -= split;
    } else {
      _range = split;
    }
    while (_range < 128) {
      if (_position >= _end) {
        throw const FormatException('Truncated VP9 arithmetic partition');
      }
      final next = (_bytes[_position >> 3] >> (7 - (_position & 7))) & 1;
      _position++;
      _value = (_value << 1) | next;
      _range <<= 1;
    }
    return one ? 1 : 0;
  }

  int literal(int width) {
    var value = 0;
    for (var i = 0; i < width; i++) {
      value = (value << 1) | bit(128);
    }
    return value;
  }

  int tree(List<int> tree, List<int> probabilities, int offset) {
    var node = 0;
    do {
      node = tree[node + bit(probabilities[offset + (node >> 1)])];
    } while (node > 0);
    return -node;
  }

  int update(int probability) {
    if (bit(252) == 0) return probability;
    var index = 0;
    if (bit(128) == 0) {
      index = literal(4);
    } else if (bit(128) == 0) {
      index = 16 + literal(4);
    } else if (bit(128) == 0) {
      index = 32 + literal(5);
    } else {
      final first = literal(7);
      index = first < 65 ? first + 64 : (first << 1) - 1 + bit(128);
    }
    final value = probabilityRemap[index];
    final low = probability <= 128;
    final center = low ? probability - 1 : 255 - probability;
    final next = value > 2 * center
        ? value
        : center + (value.isEven ? value >> 1 : -((value + 1) >> 1));
    return low ? 1 + next : 255 - next;
  }
}

enum Vp9Probability {
  coefficient(defaultCoefficientProbabilities),
  transform(defaultTransformProbabilities),
  skip(defaultSkipProbabilities),
  partition(defaultPartitionProbabilities),
  yMode(defaultYModeProbabilities),
  uvMode(defaultUvModeProbabilities),
  interMode(defaultInterModeProbabilities),
  interpolation(defaultInterpolationProbabilities),
  isInter(defaultIsInterProbabilities),
  compoundMode(defaultCompoundModeProbabilities),
  compoundRef(defaultCompoundRefProbabilities),
  singleRef(defaultSingleRefProbabilities),
  mvJoint(defaultMvJointProbabilities),
  mvSign(defaultMvSignProbabilities),
  mvClass(defaultMvClassProbabilities),
  mvClassZero(defaultMvClassZeroProbabilities),
  mvBits(defaultMvBitProbabilities),
  mvClassZeroFraction(defaultMvClassZeroFractionProbabilities),
  mvFraction(defaultMvFractionProbabilities),
  mvClassZeroHigh(defaultMvClassZeroHighProbabilities),
  mvHigh(defaultMvHighProbabilities);

  const Vp9Probability(this.defaults);

  final List<int> defaults;
}

final class Vp9EntropyContext {
  Vp9EntropyContext._(this._values);

  static final defaults = Vp9EntropyContext._([
    for (final probability in Vp9Probability.values) probability.defaults,
  ]);

  final List<List<int>> _values;
}

/// Probabilities used while decoding one frame. Compressed headers perform
/// forward updates. Non-parallel frames can also adapt from observed branches.
final class Vp9FrameEntropy {
  Vp9FrameEntropy(Uint8List bytes, Vp9FrameHeader header, this._base)
    : _values = [
        for (final values in _base._values) Uint8List.fromList(values),
      ],
      _counts =
          header.refreshContext && !header.parallel && !header.errorResilient
          ? [for (final values in _base._values) Uint32List(values.length * 2)]
          : null {
    final reader = Vp9BoolReader(
      bytes,
      header.compressedHeaderOffset,
      header.compressedHeaderLength,
    );
    var mode = header.lossless ? 0 : reader.literal(2);
    if (mode == 3) mode += reader.bit(128);
    selectTransform = mode == 4;
    largestTransform = selectTransform ? 3 : mode;
    final transform = _values[Vp9Probability.transform.index];
    if (selectTransform) {
      for (var size = 1; size <= 3; size++) {
        for (var context = 0; context < 2; context++) {
          for (var node = 0; node < size; node++) {
            final index = size * 6 + context * 3 + node;
            transform[index] = reader.update(transform[index]);
          }
        }
      }
    }
    final coefficients = _values[Vp9Probability.coefficient.index];
    for (var size = 0; size <= largestTransform; size++) {
      if (reader.bit(128) == 0) continue;
      for (var plane = 0; plane < 2; plane++) {
        for (var inter = 0; inter < 2; inter++) {
          for (var band = 0; band < 6; band++) {
            for (var context = 0; context < (band == 0 ? 3 : 6); context++) {
              final index = coefficientOffset(
                size,
                plane,
                inter,
                band,
                context,
              );
              for (var node = 0; node < 3; node++) {
                coefficients[index + node] = reader.update(
                  coefficients[index + node],
                );
              }
            }
          }
        }
      }
    }
    _update(reader, Vp9Probability.skip);
    if (header.intra) return;
    _update(reader, Vp9Probability.interMode);
    if (header.interpolation == null)
      _update(reader, Vp9Probability.interpolation);
    _update(reader, Vp9Probability.isInter);
    final biases = header.referenceBiases;
    if ((biases[0] != biases[1] || biases[0] != biases[2]) &&
        reader.bit(128) != 0) {
      referenceMode = 1 + reader.bit(128);
      final (fixed, ref0, ref1) = biases[0] == biases[1]
          ? (3, 1, 2)
          : biases[0] == biases[2]
          ? (2, 1, 3)
          : (1, 2, 3);
      fixedReference = fixed;
      variableRef0 = ref0;
      variableRef1 = ref1;
    }
    if (referenceMode == 2) _update(reader, Vp9Probability.compoundMode);
    if (referenceMode != 1) _update(reader, Vp9Probability.singleRef);
    if (referenceMode != 0) _update(reader, Vp9Probability.compoundRef);
    _update(reader, Vp9Probability.yMode);
    _update(reader, Vp9Probability.partition);
    _updateMotion(reader, header.highPrecisionMotion);
  }

  final Vp9EntropyContext _base;
  final List<Uint8List> _values;
  final List<Uint32List>? _counts;
  late final bool selectTransform;
  late final int largestTransform;
  // 0 selects a single reference, 1 always compounds, 2 signals it per block.
  int referenceMode = 0;
  int fixedReference = 0, variableRef0 = 0, variableRef1 = 0;

  int probability(Vp9Probability table, int index) =>
      _values[table.index][index];

  int bit(Vp9BoolReader reader, Vp9Probability table, int index) {
    final value = reader.bit(probability(table, index));
    count(table, index, value);
    return value;
  }

  void count(Vp9Probability table, int index, int bit) {
    if (_counts case final counts?) {
      counts[table.index][index * 2 + bit]++;
    }
  }

  int tree(
    Vp9BoolReader reader,
    List<int> tree,
    Vp9Probability table,
    int offset,
  ) {
    var node = 0;
    do {
      node = tree[node + bit(reader, table, offset + (node >> 1))];
    } while (node > 0);
    return -node;
  }

  Vp9EntropyContext save({required bool intra, required bool previousKey}) {
    final counts = _counts;
    if (counts != null) {
      for (final table in Vp9Probability.values) {
        final coefficient = table == Vp9Probability.coefficient;
        if (intra && !coefficient) continue;
        final values = _values[table.index],
            previous = _base._values[table.index];
        final branches = counts[table.index];
        final saturation = coefficient ? 24 : 20;
        final maxFactor = coefficient && (intra || !previousKey) ? 112 : 128;
        for (var i = 0; i < values.length; i++) {
          final zeros = branches[i * 2], ones = branches[i * 2 + 1];
          final total = zeros + ones;
          final factor = maxFactor * math.min(total, saturation) ~/ saturation;
          final calculated = total == 0
              ? 128
              : ((zeros * 256 + (total >> 1)) ~/ total).clamp(1, 255);
          values[i] =
              (previous[i] * (256 - factor) + calculated * factor + 128) >> 8;
        }
      }
    }
    return Vp9EntropyContext._(_values);
  }

  void _update(Vp9BoolReader reader, Vp9Probability table) {
    final values = _values[table.index];
    for (var i = 0; i < values.length; i++) {
      values[i] = reader.update(values[i]);
    }
  }

  void _updateMotion(Vp9BoolReader reader, bool highPrecision) {
    void update(Vp9Probability table, int start, int length) {
      final values = _values[table.index];
      for (var i = start; i < start + length; i++) {
        if (reader.bit(252) != 0) values[i] = (reader.literal(7) << 1) | 1;
      }
    }

    update(Vp9Probability.mvJoint, 0, 3);
    for (var axis = 0; axis < 2; axis++) {
      update(Vp9Probability.mvSign, axis, 1);
      update(Vp9Probability.mvClass, axis * 10, 10);
      update(Vp9Probability.mvClassZero, axis, 1);
      update(Vp9Probability.mvBits, axis * 10, 10);
    }
    for (var axis = 0; axis < 2; axis++) {
      update(Vp9Probability.mvClassZeroFraction, axis * 6, 6);
      update(Vp9Probability.mvFraction, axis * 3, 3);
    }
    if (highPrecision) {
      for (var axis = 0; axis < 2; axis++) {
        update(Vp9Probability.mvClassZeroHigh, axis, 1);
        update(Vp9Probability.mvHigh, axis, 1);
      }
    }
  }

  static int coefficientOffset(
    int tx,
    int plane,
    int inter,
    int band,
    int context,
  ) => ((((tx * 2 + plane) * 2 + inter) * 6 + band) * 6 + context) * 3;
}
