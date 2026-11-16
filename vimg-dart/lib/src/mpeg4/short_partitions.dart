part of 'decoder.dart';

_Vlc _partitionCodes(List<String> words) => _Vlc([
  for (final word in words) ...[int.parse(word, radix: 2), word.length],
]);

// Tables V.1 and V.2. Within each mode, entries are ordered by CBPC.
final _partitionIntra = _partitionCodes([
  '1',
  '010',
  '0110',
  '01110',
  '00100',
  '011110',
  '001100',
  '0111110',
  '0011100',
]);
final _partitionInter = _partitionCodes([
  '1',
  '010',
  '011110',
  '00100',
  '0011100',
  '01110',
  '011111110',
  '00011000',
  '01111111110',
  '0110',
  '00111100',
  '01111110',
  '000010000',
  '001100',
  '000111000',
  '001111100',
  '0001000',
  '0111110',
  '0000110000',
  '0001111000',
  '0011111100',
  '00111111100',
  '00011111000',
  '00001110000',
  '00000100000',
  '0111111110',
]);

// Tables V.3–V.5, with the skipped mode in entry zero.
final _partitionB = _partitionCodes([
  '1',
  '010',
  '001100',
  '00100',
  '011110',
  '01111110',
  '0110',
  '01110',
  '00111100',
  '0011100',
  '0001000',
  '0111110',
  '00011000',
  '011111110',
  '001111100',
]);
final _partitionEp = _partitionCodes([
  '1',
  '010',
  '0110',
  '01110',
  '00100',
  '011110',
  '001100',
  '0111110',
  '0011100',
  '0001000',
  '01111110',
  '00111100',
]);
final _partitionEi = _partitionCodes([
  '1',
  '010',
  '0110',
  '01110',
  '00100',
  '011110',
  '001100',
  '0111110',
  '0011100',
  '0001000',
  '01111110',
  '00111100',
  '00011000',
  '011111110',
  '001111100',
  '000111000',
  '000010000',
  '0111111110',
]);

// Tables V.6 and V.7.
final _partitionPb = _partitionCodes(['010', '0110', '01110']);
final _partitionImprovedPb = _partitionCodes([
  '010',
  '0110',
  '01110',
  '00100',
  '011110',
  '001100',
]);

final class _H263PartitionBlock {
  _H263PartitionBlock(this.mode, this.pbMode);

  final int mode, pbMode;
  List<_Vector> motion = const [];
  _Vector? delta;
}

final class _H263PartitionVectors {
  _H263PartitionVectors(this.bits);

  final Rbsp bits;
  var _pendingOne = false;
  var count = 0;

  _Vector read() {
    count++;
    return (x: _component(), y: _component());
  }

  int _component() {
    final value = h263ReversibleComponent(bits);
    if (value == 1 && _pendingOne) {
      h263Marker(bits);
      _pendingOne = false;
    } else {
      _pendingOne = value == 1;
    }
    return value;
  }
}

extension _H263DataPartitions on _H263Macroblocks {
  List<_H263PartitionBlock> _readDataPartitions(int count, int end) {
    final (table, stuffing) = switch ((
      header.bidirectional,
      header.enhancementIntra,
      header.enhancement,
      header.intra,
    )) {
      (true, _, _, _) => (_partitionB, _h263BModes.length),
      (_, true, _, _) => (_partitionEi, 17),
      (_, _, true, _) => (_partitionEp, _h263EpModes.length),
      (_, _, _, true) => (_partitionIntra, 8),
      _ => (_partitionInter, 25),
    };
    final blocks = <_H263PartitionBlock>[];
    // Translate Table V.2's macroblock types into the usual mode flags.
    const interModes = [0, 8, 16, 4, 12, 24];
    const headerMarker = 0x145;
    var foundMarker = false;
    while (_bits.position + 9 <= end) {
      final start = _bits.position;
      if (_bits.read(9) == headerMarker) {
        foundMarker = true;
        break;
      }
      _bits.position = start;
      final code = table.read(_bits);
      if (code == stuffing) continue;
      if (blocks.length == count) {
        throw const FormatException(
          'Too many macroblocks in H.263+ header partition',
        );
      }
      final mode = header.intra || header.enhancement || header.bidirectional
          ? code
          : code == 0
          ? -1
          : interModes[(code - 1) >> 2] | ((code - 1) & 3);
      final pbMode = _pb == null || mode == -1
          ? 0
          : (header.extended ? _partitionImprovedPb : _partitionPb).read(_bits);
      blocks.add(_H263PartitionBlock(mode, pbMode));
    }
    if (!foundMarker || blocks.length != count) {
      throw const FormatException(
        'Invalid H.263+ header partition marker or macroblock count',
      );
    }

    // Each slice starts one forward motion prediction chain. Backward
    // B-prediction and MVDB keep their respective macroblock predictors.
    final vectors = _H263PartitionVectors(_bits);
    var lastMotion = _zeroVector;
    var hasSecondary = false;
    _Vector nextMotion(int _) {
      final delta = vectors.read();
      lastMotion = (x: lastMotion.x + delta.x, y: lastMotion.y + delta.y);
      return lastMotion;
    }

    for (final block in blocks) {
      final (primary, secondary) = _partitionMotionCounts(block);
      if (primary != 0) {
        block.motion = List.generate(primary, nextMotion, growable: false);
      }
      if (secondary) {
        block.delta = vectors.read();
        hasSecondary = true;
      }
      if (_bits.position > end) {
        throw const FormatException(
          'H.263+ motion partition exceeds its slice',
        );
      }
    }
    if (vectors.count > 1) {
      final repeated = vectors.read();
      if (!hasSecondary && repeated != lastMotion) {
        throw const FormatException(
          'H.263+ motion partition has an inconsistent last vector',
        );
      }
    }
    if (vectors.count != 0 &&
        (_bits.position + 10 > end || _bits.read(10) != 1)) {
      throw const FormatException('Invalid H.263+ motion partition marker');
    }
    return blocks;
  }

  _Vector _readSecondaryVector(_Vector prediction) {
    final partition = _partition;
    if (partition == null) return _readVector(prediction);
    final delta = partition.delta!;
    if (header.format.unrestricted) {
      return (x: prediction.x + delta.x, y: prediction.y + delta.y);
    }
    return (
      x: _addMotionDifference(prediction.x, delta.x, 32, header.longVectors),
      y: _addMotionDifference(prediction.y, delta.y, 32, header.longVectors),
    );
  }

  (int, bool) _partitionMotionCounts(_H263PartitionBlock block) {
    final mode = block.mode;
    if (header.intra || header.enhancementIntra || mode == -1) {
      return (0, false);
    }
    if (header.bidirectional) {
      final (prediction, _, _) = _h263BModes[mode];
      return (
        prediction == _H263BPrediction.forward ||
                prediction == _H263BPrediction.both
            ? 1
            : 0,
        prediction == _H263BPrediction.backward ||
            prediction == _H263BPrediction.both,
      );
    }
    if (header.enhancement) {
      final (prediction, texture, _) = _h263EpModes[mode];
      return (
        texture &&
                (prediction == _LayerPrediction.forward ||
                    prediction == _LayerPrediction.blend)
            ? 1
            : 0,
        false,
      );
    }
    final intra = mode & 4 != 0;
    final directPb =
        _pb != null &&
        _h263PbPrediction(block.pbMode, improved: header.extended) ==
            _PbMode.direct;
    return (
      !intra || directPb ? (mode & 16 != 0 ? 4 : 1) : 0,
      _pb != null && _h263PbHasVector(block.pbMode, improved: header.extended),
    );
  }
}
