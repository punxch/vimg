part of 'decoder.dart';

final class _PartitionMacroblock {
  _PartitionMacroblock(this.mode, {required this.intra});

  final int mode;
  final bool intra;
  int quant = 0, pattern = 0;
  bool acPrediction = false;
  List<int>? dc;
}

extension _DataPartitions on _VopDecoder {
  void _decodePartitions() {
    final intra = header.type == Mpeg4PictureType.intra;
    final count = _columns * picture.rows;
    var start = 0;
    while (start < count) {
      if (start != 0 && !_readPacketHeader(start)) {
        throw const FormatException('Missing MPEG-4 partition video packet');
      }
      final macroblocks = _readFirstPartition(start, count, intra);
      _readSecondPartition(macroblocks, intra);
      _readTexturePartition(start, macroblocks);
      start += macroblocks.length;
    }
  }

  // I-VOPs carry DC differences here. P-VOPs carry skip flags and motion
  // vectors, then place any intra DC differences in the second partition.
  List<_PartitionMacroblock?> _readFirstPartition(
    int start,
    int count,
    bool intra,
  ) {
    final macroblocks = <_PartitionMacroblock?>[];
    while (!_partitionMarker(intra)) {
      final skipped = !intra && _bits.flag();
      final mode = skipped
          ? 0
          : (intra ? _intraMacroblock : _interMacroblock).read(_bits);
      if (!skipped && mode == (intra ? 8 : 20)) continue;
      final index = start + macroblocks.length;
      if (index >= count) {
        throw const FormatException('Missing MPEG-4 data partition marker');
      }
      if (skipped) {
        picture.motion.skipped[index] = 1;
        macroblocks.add(null);
      } else {
        final block = _PartitionMacroblock(mode, intra: intra || mode & 4 != 0);
        if (intra) {
          _readPartitionQuantAndDc(block, mode & 4 != 0, macroblocks.isEmpty);
        } else if (!block.intra) {
          _readFrameVectors(
            index % _columns,
            index ~/ _columns,
            index,
            mode & 16 != 0,
          );
        }
        macroblocks.add(block);
      }
    }
    if (macroblocks.isEmpty) {
      throw const FormatException('Empty MPEG-4 data partition');
    }
    return macroblocks;
  }

  bool _partitionMarker(bool intra) {
    final length = intra ? 19 : 17;
    if (_bits.remaining < length) return false;
    final position = _bits.position;
    if (_bits.read(length) == (intra ? 0x6b001 : 0x1f001)) return true;
    _bits.position = position;
    return false;
  }

  void _readSecondPartition(
    List<_PartitionMacroblock?> macroblocks,
    bool intra,
  ) {
    var firstCoded = true;
    for (final block in macroblocks) {
      if (block == null) continue;
      block.acPrediction = block.intra && _bits.flag();
      final luma = _lumaPattern.read(_bits);
      block.pattern =
          ((block.intra ? luma : luma ^ 15) << 2) | (block.mode & 3);
      if (!intra) {
        _readPartitionQuantAndDc(block, block.mode & 8 != 0, firstCoded);
      }
      firstCoded = false;
    }
  }

  void _readPartitionQuantAndDc(
    _PartitionMacroblock block,
    bool changeQuant,
    bool firstCoded,
  ) {
    final previousQuant = _quant;
    if (changeQuant) _adjustQuant(_quantChange[_bits.read(2)]);
    block.quant = _quant;
    if (block.intra && (firstCoded ? _quant : previousQuant) < _threshold) {
      block.dc = [for (var i = 0; i < 6; i++) _readDcDifference(_bits, i < 4)];
    }
  }

  void _readTexturePartition(
    int start,
    List<_PartitionMacroblock?> macroblocks,
  ) {
    final motion = picture.motion;
    for (final (i, block) in macroblocks.indexed) {
      final index = start + i, x = index % _columns, y = index ~/ _columns;
      if (block != null) _quant = block.quant;
      if (block != null && block.intra) {
        _readIntraBlocks(
          x,
          y,
          block.pattern,
          separateDc: block.dc != null,
          acPrediction: block.acPrediction,
          dc: block.dc,
        );
      } else {
        final split = motion.split[index] != 0;
        _prediction.predict(picture, past!, x, y, [
          for (var j = 0; j < (split ? 4 : 1); j++)
            motion.at(x * 2 + (j & 1), y * 2 + (j >> 1)),
        ], noRound: header.noRound);
        if (block != null) _readResidual(x, y, block.pattern, false);
      }
    }
  }
}
