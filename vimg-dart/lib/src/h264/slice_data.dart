import 'dart:math' as math;
import 'dart:typed_data';

import 'b_motion.dart';
import 'cabac.dart';
import 'cavlc.dart';
import 'motion.dart';
import 'reference.dart';
import 'slice_header.dart';

part 'b_slice.dart';
part 'cabac_slice.dart';
part 'cavlc_slice.dart';
part 'p_slice.dart';

int blockX(int block) => (block & 1) | ((block >> 1) & 2);
int blockY(int block) => ((block >> 1) & 1) | ((block >> 2) & 2);
int blockIndex(int x, int y) =>
    ((y & 2) << 2) | ((x & 2) << 1) | ((y & 1) << 1) | (x & 1);

final class Macroblock {
  Macroblock(this.slice, this.type);

  final SliceHeader slice;
  final int type;
  bool get intra => type >= 0;
  bool get pcm => type == 25;
  bool get nxn => type == 0;
  bool get intra16 => type > 0 && type < 25;

  var transform8x8 = false;
  var skipped = false, direct = false;
  var lumaPattern = 0, chromaPattern = 0;
  var chromaMode = 0;
  // Signed QPY before adding the bit-depth offset for inverse quantization.
  var qp = 0;
  var codedLuma = 0, codedChroma = 0, codedDc = 0;
  Uint8List? modes;
  Uint8List? totalCoefficients;

  int predictionMode(int x, int y) => modes?[y * 4 + x] ?? 2;
}

/// Coefficients remain in zigzag order here. The reconstruction stage maps
/// them to the transform matrix. These buffers belong to one slice reader
/// and are reused immediately after reconstructing a macroblock.
final class MacroblockCoefficients {
  final luma = Int32List(256);
  final lumaDc = Int32List(16);
  final chroma = Int32List(128);
  final chromaDc = Int32List(8);
  final pcm = Uint16List(384);

  void clearResiduals() {
    luma.fillRange(0, luma.length, 0);
    lumaDc.fillRange(0, lumaDc.length, 0);
    chroma.fillRange(0, chroma.length, 0);
    chromaDc.fillRange(0, chromaDc.length, 0);
  }
}

abstract class SliceData {
  SliceData(this.header) : _qp = header.qp;

  final SliceHeader header;
  final coefficients = MacroblockCoefficients();
  var _previousQpDelta = false;
  int _qp;

  void _updateQp(int delta) {
    final offset = header.pps.sps.lumaQpOffset;
    if (delta < -26 - offset ~/ 2 || delta > 25 + offset ~/ 2) {
      throw const FormatException('Invalid H.264 macroblock QP delta');
    }
    _qp = (_qp + delta + offset) % (52 + offset) - offset;
  }

  bool endOfSlice();
  bool _skip(Macroblock? left, Macroblock? top);
  int _pType();
  int _pSubType();
  int _bType(int context);
  int _bSubType();
  int _intraType(Macroblock? left, Macroblock? top, int? type);
  bool _transformFlag(Macroblock? left, Macroblock? top);
  int? _intraRemainder();
  int _chromaMode(Macroblock? left, Macroblock? top);
  int _referenceIndex(int context, int active);
  (int, int) _motionDelta(MotionField field, MotionPartition part, int owner);
  void _patterns(Macroblock block, Macroblock? left, Macroblock? top);
  void _readQuantizerAndResiduals(
    Macroblock block,
    Macroblock? left,
    Macroblock? top,
  );
  void _restartAfterPcm() {}

  void _interResiduals(
    Macroblock block,
    Macroblock? left,
    Macroblock? top,
    bool allow8x8,
  ) {
    _patterns(block, left, top);
    if (header.pps.transform8x8 && block.lumaPattern != 0 && allow8x8) {
      block.transform8x8 = _transformFlag(left, top);
    }
    _readQuantizerAndResiduals(block, left, top);
  }

  void _readVector(
    MotionField field,
    MotionPartition part,
    int owner,
    int ref,
  ) {
    final (dx, dy) = _motionDelta(field, part, owner);
    final predicted = field.predict(part, owner, ref);
    final vector = (
      x: signedMotion(predicted.x + dx),
      y: signedMotion(predicted.y + dy),
    );
    field.setVector(part, vector, (x: dx, y: dy));
  }

  Macroblock readIntra(Macroblock? left, Macroblock? top, [int? type]) {
    final block = Macroblock(header, _intraType(left, top, type));
    if (block.pcm) {
      final bits = header.bits;
      bits.align(0);
      final sps = header.pps.sps;
      block.qp = -sps.lumaQpOffset;
      final count = sps.chromaFormat == 0 ? 256 : 384;
      for (var i = 0; i < count; i++) {
        coefficients.pcm[i] = bits.read(
          i < 256 ? sps.lumaDepth : sps.chromaDepth,
        );
      }
      _restartAfterPcm();
      _previousQpDelta = false;
      return block;
    }
    if (block.nxn) {
      if (header.pps.transform8x8) {
        block.transform8x8 = _transformFlag(left, top);
      }
      _predictionModes(block, left, top);
    } else {
      block.lumaPattern = block.type >= 13 ? 15 : 0;
      if (header.pps.sps.chromaFormat != 0) {
        block.chromaPattern = ((block.type - 1) ~/ 4) % 3;
      }
    }
    if (header.pps.sps.chromaFormat == 1) {
      block.chromaMode = _chromaMode(left, top);
    }
    if (block.nxn) _patterns(block, left, top);
    _readQuantizerAndResiduals(block, left, top);
    return block;
  }

  void _predictionModes(Macroblock block, Macroblock? left, Macroblock? top) {
    block.modes = Uint8List(16);
    final step = block.transform8x8 ? 2 : 1;
    final count = step == 2 ? 4 : 16;
    for (var index = 0; index < count; index++) {
      final x = blockX(index * step * step);
      final y = blockY(index * step * step);
      var a = x == 0 ? left : block;
      var b = y == 0 ? top : block;
      if (header.pps.constrainedIntra) {
        if (a?.intra == false) a = null;
        if (b?.intra == false) b = null;
      }
      var mode = a == null || b == null
          ? 2
          : math.min(
              a.predictionMode((x - 1) & 3, y),
              b.predictionMode(x, (y - 1) & 3),
            );
      final remainder = _intraRemainder();
      if (remainder != null)
        mode = remainder < mode ? remainder : remainder + 1;
      for (var dy = 0; dy < step; dy++) {
        block.modes!.fillRange((y + dy) * 4 + x, (y + dy) * 4 + x + step, mode);
      }
    }
  }
}
