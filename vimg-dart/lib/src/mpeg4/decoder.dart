import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as image;

import '../mpeg12/syntax.dart' show mpegZigzag;
import '../mpeg_idct.dart';
import '../rbsp.dart';
import '../yuv_image.dart';
import 'short_header.dart';
import 'syntax.dart';
import 'tables.dart';

part 'blocks.dart';
part 'motion.dart';
part 'partitions.dart';
part 'short_annex.dart';
part 'short_b.dart';
part 'short_layers.dart';
part 'short_overlap.dart';
part 'short_pb.dart';
part 'short_reduced.dart';
part 'short_resample.dart';
part 'short_sac.dart';
part 'short_sac_models.dart';
part 'short_segments.dart';
part 'short_slices.dart';
part 'short_video.dart';

class _DctPicture {
  _DctPicture(
    this.width,
    this.height, {
    this.quarter = false,
    int alignment = 16,
  }) : columns = ((width + alignment - 1) & -alignment) >> 4,
       rows = ((height + alignment - 1) & -alignment) >> 4 {
    final macroblocks = columns * rows;
    planes = [
      Uint8List(macroblocks * 256),
      Uint8List(macroblocks * 64),
      Uint8List(macroblocks * 64),
    ];
  }

  final int width, height, columns, rows;
  final bool quarter;
  int get stride => columns * 16;

  late final List<Uint8List> planes;
}

final class Mpeg4Picture extends _DctPicture {
  Mpeg4Picture._(this.volume, this.pts)
    : super(volume.width, volume.height, quarter: volume.quarter) {
    motion = _PictureMotion(columns, rows, volume.interlaced);
  }

  final Mpeg4Volume volume;
  final int pts;
  late final _PictureMotion motion;

  image.Image rgb({YuvImageScaler? scaler}) => yuvImage(
    y: planes[0],
    cb: planes[1],
    cr: planes[2],
    stride: stride,
    chromaStride: stride >> 1,
    width: volume.width,
    height: volume.height,
    cropLeft: 0,
    cropTop: 0,
    matrix: volume.signal.matrix,
    fullRange: volume.signal.fullRange,
    sampleAspect: volume.aspect,
    scaler: scaler,
  );
}

/// Decodes pictures in coded order. Non-coded VOPs can repeat a reference.
final class Mpeg4Decoder {
  Mpeg4Decoder([Uint8List? configuration, Mpeg4Clock? clock]) {
    if (configuration != null) _headers.read(configuration).toList();
    if (clock != null) _headers.restoreClock(clock);
  }

  final _headers = Mpeg4Headers();
  final _transform = MpegIdct();
  Mpeg4Picture? _past, _future;

  Iterable<Mpeg4Picture> decode(
    Uint8List bytes, {
    bool includeBidirectional = true,
  }) sync* {
    for (final unit in _headers.read(bytes)) {
      final header = unit.header;
      final bidirectional = header.type == Mpeg4PictureType.bidirectional;
      if (bidirectional && !includeBidirectional) continue;
      if (!header.coded) {
        if (_future case final repeat?) yield repeat;
        continue;
      }
      final old = header.type == Mpeg4PictureType.intra
          ? null
          : bidirectional
          ? _past
          : _future;
      final next = bidirectional ? _future : null;
      if (header.type != Mpeg4PictureType.intra &&
          (old == null || bidirectional && next == null)) {
        throw const FormatException('Missing MPEG-4 reference picture');
      }
      final picture = Mpeg4Picture._(header.volume, header.pts);
      for (final reference in [old, next]) {
        if (reference != null &&
            (reference.columns != picture.columns ||
                reference.rows != picture.rows)) {
          throw const FormatException(
            'MPEG-4 reference picture dimensions changed',
          );
        }
      }
      _VopDecoder(header, picture, old, next, _transform).decode();
      if (!bidirectional) {
        _past = _future;
        _future = picture;
      }
      yield picture;
    }
  }
}

const _quantChange = [-1, -2, 1, 2];

final class _VopDecoder {
  _VopDecoder(
    this.header,
    this.picture,
    this.past,
    this.future,
    this._transform,
  ) : _quant = header.quant,
      _threshold = header.dcThreshold,
      _forwardCode = header.forwardCode,
      _backwardCode = header.backwardCode,
      _globalMotion = header.globalMotion,
      _intra = [
        List<_IntraBlock?>.filled(picture.columns * picture.rows * 4, null),
        List<_IntraBlock?>.filled(picture.columns * picture.rows, null),
        List<_IntraBlock?>.filled(picture.columns * picture.rows, null),
      ];

  final Mpeg4Vop header;
  final Mpeg4Picture picture;
  final Mpeg4Picture? past, future;
  final MpegIdct _transform;
  final _prediction = _Mpeg4MotionCompensation();
  final List<List<_IntraBlock?>> _intra;
  final _coefficients = Int16List(64);
  Rbsp get _bits => header.bits;
  int get _columns => picture.columns;
  final _rowVectors = List<_Vector>.filled(4, _zeroVector);
  int _quant, _threshold, _forwardCode, _backwardCode;
  int _sliceStart = 0;
  Mpeg4Gmc? _globalMotion;

  void decode() {
    if (header.volume.partitioned &&
        header.type != Mpeg4PictureType.bidirectional) {
      _decodePartitions();
      return;
    }
    for (var y = 0; y < picture.rows; y++) {
      _rowVectors.fillRange(0, 4, _zeroVector);
      for (var x = 0; x < _columns; x++) {
        final index = y * _columns + x;
        if (index != 0 && header.volume.resync) _readPacketHeader(index);
        switch (header.type) {
          case Mpeg4PictureType.intra:
            var mode = _intraMacroblock.read(_bits);
            while (mode == 8) {
              mode = _intraMacroblock.read(_bits);
            }
            _readIntra(x, y, mode, (mode & 4) != 0);
          case Mpeg4PictureType.predictive:
          case Mpeg4PictureType.sprite:
            _readPredictive(x, y, index);
          case Mpeg4PictureType.bidirectional:
            _readBidirectional(x, y, index);
        }
      }
    }
  }

  bool _readPacketHeader(int index) {
    final zeroes = switch (header.type) {
      Mpeg4PictureType.intra => 16,
      Mpeg4PictureType.bidirectional =>
        15 + math.max<int>(2, math.max<int>(_forwardCode, _backwardCode)),
      _ => 15 + _forwardCode,
    };
    final saved = _bits.position;
    final pad = 8 - (saved & 7);
    final addressBits = (picture.columns * picture.rows - 1).bitLength;
    if (_bits.remaining <
        pad + zeroes + addressBits + header.volume.quantBits + 2)
      return false;
    if (_bits.read(pad) != (1 << (pad - 1)) - 1 ||
        _bits.read(zeroes + 1) != 1) {
      _bits.position = saved;
      return false;
    }
    final address = _bits.read(addressBits);
    if (address != index) {
      _bits.position = saved;
      // A skipped B macroblock consumes no bits before the next packet.
      if (future?.motion.skipped[index] == 1 && address > index) return false;
      throw const FormatException('Invalid MPEG-4 video packet address');
    }
    _sliceStart = index;
    _rowVectors.fillRange(0, 4, _zeroVector);
    final quant = _bits.read(header.volume.quantBits);
    if (quant != 0) _quant = quant;
    if (_bits.flag()) {
      while (_bits.flag()) {}
      mpeg4Marker(_bits);
      _bits.skip(header.volume.incrementBits);
      mpeg4Marker(_bits);
      if (_bits.read(2) != header.type.index) {
        throw const FormatException('MPEG-4 video packet changes picture type');
      }
      _threshold = mpeg4DcThreshold[_bits.read(3)];
      if (_globalMotion case final global?) {
        _globalMotion = Mpeg4Gmc.read(
          _bits,
          header.volume,
          legacyDivx: global.legacyDivx,
        );
      }
      if (header.type != Mpeg4PictureType.intra) _forwardCode = _bits.read(3);
      if (header.type == Mpeg4PictureType.bidirectional)
        _backwardCode = _bits.read(3);
      if (_forwardCode == 0 || _backwardCode == 0) {
        throw const FormatException('Invalid MPEG-4 video packet motion range');
      }
    }
    return true;
  }

  void _adjustQuant(int delta) {
    _quant = (_quant + delta).clamp(1, (1 << header.volume.quantBits) - 1);
  }

  void _readIntra(int x, int y, int mode, bool changeQuant) {
    final acPrediction = _bits.flag();
    final pattern = (_lumaPattern.read(_bits) << 2) | (mode & 3);
    final separateDc = _quant < _threshold;
    if (changeQuant) _adjustQuant(_quantChange[_bits.read(2)]);
    final fieldDct = header.volume.interlaced && _bits.flag();
    _readIntraBlocks(
      x,
      y,
      pattern,
      separateDc: separateDc,
      acPrediction: acPrediction,
      fieldDct: fieldDct,
    );
  }

  void _readIntraBlocks(
    int x,
    int y,
    int pattern, {
    required bool separateDc,
    required bool acPrediction,
    bool fieldDct = false,
    List<int>? dc,
  }) {
    for (var block = 0; block < 6; block++) {
      _readBlock(
        x,
        y,
        block,
        coded: pattern & (32 >> block) != 0,
        intra: true,
        separateDc: separateDc,
        acPrediction: acPrediction,
        fieldDct: fieldDct,
        dcDifference: dc?[block],
      );
    }
  }

  void _readPredictive(int x, int y, int index) {
    final reference = past!;
    var mode = 20; // stuffing
    while (mode == 20) {
      if (_bits.flag()) {
        if (_globalMotion != null) {
          _saveGlobalVector(x, y);
          _predictGlobal(x, y);
        } else {
          picture.motion.skipped[index] = 1;
          _prediction.predict(picture, reference, x, y, [
            _zeroVector,
          ], noRound: header.noRound);
        }
        return;
      }
      mode = _interMacroblock.read(_bits);
    }
    final changeQuant = mode & 8 != 0;
    if (mode & 4 != 0) {
      _readIntra(x, y, mode, changeQuant);
      return;
    }
    final split = mode & 16 != 0;
    final global = _globalMotion != null && !split && _bits.flag();
    final pattern = ((_lumaPattern.read(_bits) ^ 15) << 2) | (mode & 3);
    if (changeQuant) _adjustQuant(_quantChange[_bits.read(2)]);
    final fieldDct = header.volume.interlaced && pattern != 0 && _bits.flag();
    if (global) {
      _saveGlobalVector(x, y);
      _predictGlobal(x, y);
      _readResidual(x, y, pattern, fieldDct);
      return;
    }
    if (header.volume.interlaced && !split && _bits.flag()) {
      final selection = _readFieldSelection();
      final prediction = _predictVector(x, y, 0);
      final motion = _readFieldMotion(
        selection,
        prediction,
        prediction,
        _forwardCode,
      );
      picture.motion.fields![index] = motion;
      final sumX = motion.top.x + motion.bottom.x;
      final frameVector = (
        x: (sumX >> 1) | (sumX & 1),
        y: motion.top.y + motion.bottom.y,
      );
      _storeFrameVector(x, y, frameVector);
      _prediction.predictFields(
        picture,
        reference,
        x,
        y,
        motion,
        noRound: header.noRound,
      );
      _readResidual(x, y, pattern, fieldDct);
      return;
    }
    final vectors = _readFrameVectors(x, y, index, split);
    _prediction.predict(
      picture,
      reference,
      x,
      y,
      vectors,
      noRound: header.noRound,
    );
    _readResidual(x, y, pattern, fieldDct);
  }

  List<_Vector> _readFrameVectors(int x, int y, int index, bool split) {
    final vectors = <_Vector>[];
    for (var block = 0; block < (split ? 4 : 1); block++) {
      final vector = _motionVector(
        _bits,
        _predictVector(x, y, block),
        _forwardCode,
      );
      vectors.add(vector);
      if (split) picture.motion.store(x, y, block, vector);
    }
    if (split) {
      picture.motion.split[index] = 1;
    } else {
      _storeFrameVector(x, y, vectors.single);
    }
    return vectors;
  }

  void _storeFrameVector(int x, int y, _Vector vector) {
    for (var block = 0; block < 4; block++) {
      picture.motion.store(x, y, block, vector);
    }
  }

  void _saveGlobalVector(int x, int y) {
    _storeFrameVector(
      x,
      y,
      _globalMotion!.averageVector(
        x,
        y,
        _forwardCode,
        quarter: header.volume.quarter,
      ),
    );
  }

  void _predictGlobal(int x, int y) {
    _prediction.predictGlobal(
      picture,
      past!,
      x,
      y,
      _globalMotion!,
      noRound: header.noRound,
    );
  }

  void _readBidirectional(int x, int y, int index) {
    final before = past!, after = future!;
    if (after.motion.skipped[index] != 0) {
      _prediction.predict(picture, before, x, y, [_zeroVector]);
      return;
    }
    final directSkip = _bits.flag();
    final codedPattern = !directSkip && !_bits.flag();
    final mode = directSkip ? 0 : _bMacroblock.read(_bits);
    final pattern = codedPattern ? _bits.read(6) : 0;
    if (mode != 0 && pattern != 0 && _bits.flag()) {
      _adjustQuant(_bits.flag() ? 2 : -2);
    }
    final fieldDct = header.volume.interlaced && pattern != 0 && _bits.flag();
    if (mode == 0) {
      _predictDirect(x, y, index, directSkip);
    } else {
      final forwards = mode == 1 || mode == 3;
      final backwards = mode == 1 || mode == 2;
      final field = header.volume.interlaced && _bits.flag();
      final forwardSelection = field && forwards ? _readFieldSelection() : null;
      final backwardSelection = field && backwards
          ? _readFieldSelection()
          : null;
      if (forwards) {
        _predictFromRow(before, x, y, 0, _forwardCode, forwardSelection);
      }
      if (backwards) {
        _predictFromRow(
          after,
          x,
          y,
          2,
          _backwardCode,
          backwardSelection,
          average: forwards,
        );
      }
    }
    _readResidual(x, y, pattern, fieldDct);
  }

  void _predictDirect(int x, int y, int index, bool skipped) {
    final before = past!, after = future!;
    final delta = skipped ? _zeroVector : _motionVector(_bits, _zeroVector, 1);
    final period = after.pts - before.pts, offset = header.pts - before.pts;
    if (offset <= 0 || offset >= period) {
      throw const FormatException('Invalid MPEG-4 B picture timing');
    }
    if (after.motion.fields?[index] case final motion?) {
      final interval =
          header.fieldInterval ??
          (throw const FormatException('Missing MPEG-4 field time interval'));
      int fieldTime(int ticks) => 2 * ((ticks + (interval >> 1)) ~/ interval);
      final fieldPeriod = fieldTime(after.pts) - fieldTime(before.pts);
      final fieldOffset = fieldTime(header.pts) - fieldTime(before.pts);
      final direction = header.topFieldFirst ? 1 : -1;
      final topDelay = -motion.selection.top * direction;
      final bottomDelay = (1 - motion.selection.bottom) * direction;
      final top = _directVectors(
        motion.top,
        delta,
        fieldOffset + topDelay,
        fieldPeriod + topDelay,
      );
      final bottom = _directVectors(
        motion.bottom,
        delta,
        fieldOffset + bottomDelay,
        fieldPeriod + bottomDelay,
      );
      _prediction.predictFields(picture, before, x, y, (
        selection: motion.selection,
        top: top.forward,
        bottom: bottom.forward,
      ));
      _prediction.predictFields(picture, after, x, y, (
        selection: (top: 0, bottom: 1),
        top: top.backward,
        bottom: bottom.backward,
      ), average: true);
      return;
    }
    final forward = <_Vector>[], backward = <_Vector>[];
    final split = after.motion.split[index] != 0 || picture.volume.quarter;
    for (var block = 0; block < (split ? 4 : 1); block++) {
      final reference = after.motion.at(
        x * 2 + (block & 1),
        y * 2 + (block >> 1),
      );
      final vectors = _directVectors(reference, delta, offset, period);
      forward.add(vectors.forward);
      backward.add(vectors.backward);
    }
    _prediction.predict(picture, before, x, y, forward);
    _prediction.predict(picture, after, x, y, backward, average: true);
  }

  _FieldSelection _readFieldSelection() =>
      (top: _bits.bit(), bottom: _bits.bit());

  _FieldMotion _readFieldMotion(
    _FieldSelection selection,
    _Vector top,
    _Vector bottom,
    int code,
  ) => (
    selection: selection,
    top: _motionVector(_bits, (x: top.x, y: top.y ~/ 2), code),
    bottom: _motionVector(_bits, (x: bottom.x, y: bottom.y ~/ 2), code),
  );

  void _predictFromRow(
    Mpeg4Picture reference,
    int x,
    int y,
    int slot,
    int code,
    _FieldSelection? selection, {
    bool average = false,
  }) {
    if (selection == null) {
      final vector = _motionVector(_bits, _rowVectors[slot], code);
      _rowVectors[slot] = _rowVectors[slot + 1] = vector;
      _prediction.predict(picture, reference, x, y, [vector], average: average);
    } else {
      final motion = _readFieldMotion(
        selection,
        _rowVectors[slot],
        _rowVectors[slot + 1],
        code,
      );
      _rowVectors[slot] = (x: motion.top.x, y: motion.top.y * 2);
      _rowVectors[slot + 1] = (x: motion.bottom.x, y: motion.bottom.y * 2);
      _prediction.predictFields(
        picture,
        reference,
        x,
        y,
        motion,
        average: average,
      );
    }
  }

  void _readResidual(int x, int y, int pattern, bool fieldDct) {
    for (var block = 0; block < 6; block++) {
      if (pattern & (32 >> block) != 0) {
        _readBlock(x, y, block, coded: true, intra: false, fieldDct: fieldDct);
      }
    }
  }

  _Vector _predictVector(int x, int y, int block) =>
      _motionPrediction(picture.motion, _columns, _sliceStart, x, y, block);
}
