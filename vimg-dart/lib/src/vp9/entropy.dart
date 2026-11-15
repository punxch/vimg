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

final class Vp9IntraEntropy {
  Vp9IntraEntropy(Uint8List bytes, Vp9FrameHeader header) {
    final reader = Vp9BoolReader(
      bytes,
      header.compressedHeaderOffset,
      header.compressedHeaderLength,
    );
    var mode = header.lossless ? 0 : reader.literal(2);
    if (mode == 3) mode += reader.bit(128);
    selectTransform = mode == 4;
    largestTransform = selectTransform ? 3 : mode;
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
    for (var i = 0; i < skip.length; i++) {
      skip[i] = reader.update(skip[i]);
    }
  }

  late final bool selectTransform;
  late final int largestTransform;
  final transform = Uint8List.fromList(defaultTransformProbabilities);
  final coefficients = Uint8List.fromList(defaultCoefficientProbabilities);
  final skip = Uint8List.fromList(defaultSkipProbabilities);

  static int coefficientOffset(
    int tx,
    int plane,
    int inter,
    int band,
    int context,
  ) => ((((tx * 2 + plane) * 2 + inter) * 6 + band) * 6 + context) * 3;
}
