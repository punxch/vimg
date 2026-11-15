import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as image;

import '../mpeg12/syntax.dart' show mpegZigzag;
import '../mpeg_idct.dart';
import '../rbsp.dart';
import '../yuv_image.dart';
import 'syntax.dart';
import 'tables.dart';

part 'blocks.dart';
part 'motion.dart';

final class Mpeg4Picture {
  Mpeg4Picture._(this.volume, this.pts)
    : columns = (volume.width + 15) >> 4,
      rows = (volume.height + 15) >> 4 {
    final macroblocks = columns * rows;
    planes = [
      Uint8List(macroblocks * 256),
      Uint8List(macroblocks * 64),
      Uint8List(macroblocks * 64),
    ];
    motion = _PictureMotion(columns, rows);
  }

  final Mpeg4Volume volume;
  final int pts, columns, rows;
  int get stride => columns * 16;

  late final List<Uint8List> planes;
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
  Mpeg4Decoder([Uint8List? configuration]) {
    if (configuration != null) _headers.read(configuration).toList();
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
      if (header.type == Mpeg4PictureType.sprite)
        throw UnsupportedError('MPEG-4 sprite pictures');
      if (header.volume.partitioned && !bidirectional) {
        throw UnsupportedError('MPEG-4 data partitioning');
      }
      if (header.volume.interlaced)
        throw UnsupportedError('MPEG-4 interlaced pictures');
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
  final _rowVectors = List<_Vector>.filled(2, _zeroVector);
  int _quant, _threshold, _forwardCode, _backwardCode;
  int _sliceStart = 0;

  void decode() {
    for (var y = 0; y < picture.rows; y++) {
      _rowVectors.fillRange(0, 2, _zeroVector);
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
            _readPredictive(x, y, index);
          case Mpeg4PictureType.bidirectional:
            _readBidirectional(x, y, index);
          case Mpeg4PictureType.sprite:
            throw StateError('Unexpected MPEG-4 sprite picture');
        }
      }
    }
  }

  void _readPacketHeader(int index) {
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
      return;
    if (_bits.read(pad) != (1 << (pad - 1)) - 1 ||
        _bits.read(zeroes + 1) != 1) {
      _bits.position = saved;
      return;
    }
    final address = _bits.read(addressBits);
    if (address != index) {
      _bits.position = saved;
      // A skipped B macroblock consumes no bits before the next packet.
      if (future?.motion.skipped[index] == 1 && address > index) return;
      throw const FormatException('Invalid MPEG-4 video packet address');
    }
    _sliceStart = index;
    _rowVectors.fillRange(0, 2, _zeroVector);
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
      if (header.type != Mpeg4PictureType.intra) _forwardCode = _bits.read(3);
      if (header.type == Mpeg4PictureType.bidirectional)
        _backwardCode = _bits.read(3);
      if (_forwardCode == 0 || _backwardCode == 0) {
        throw const FormatException('Invalid MPEG-4 video packet motion range');
      }
    }
  }

  void _adjustQuant(int delta) {
    _quant = (_quant + delta).clamp(1, (1 << header.volume.quantBits) - 1);
  }

  void _readIntra(int x, int y, int mode, bool changeQuant) {
    final acPrediction = _bits.flag();
    final pattern = (_lumaPattern.read(_bits) << 2) | (mode & 3);
    final separateDc = _quant < _threshold;
    if (changeQuant) _adjustQuant(_quantChange[_bits.read(2)]);
    for (var block = 0; block < 6; block++) {
      _readBlock(
        x,
        y,
        block,
        coded: pattern & (32 >> block) != 0,
        intra: true,
        separateDc: separateDc,
        acPrediction: acPrediction,
      );
    }
  }

  void _readPredictive(int x, int y, int index) {
    final reference = past!;
    var mode = 20; // stuffing
    while (mode == 20) {
      if (_bits.flag()) {
        picture.motion.skipped[index] = 1;
        _prediction.predict(picture, reference, x, y, [
          _zeroVector,
        ], noRound: header.noRound);
        return;
      }
      mode = _interMacroblock.read(_bits);
    }
    final changeQuant = mode & 8 != 0;
    if (mode & 4 != 0) {
      _readIntra(x, y, mode, changeQuant);
      return;
    }
    final pattern = ((_lumaPattern.read(_bits) ^ 15) << 2) | (mode & 3);
    if (changeQuant) _adjustQuant(_quantChange[_bits.read(2)]);
    final split = mode & 16 != 0;
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
      for (var block = 0; block < 4; block++) {
        picture.motion.store(x, y, block, vectors.single);
      }
    }
    _prediction.predict(
      picture,
      reference,
      x,
      y,
      vectors,
      noRound: header.noRound,
    );
    _readResidual(x, y, pattern);
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
    if (mode == 0) {
      final delta = directSkip
          ? _zeroVector
          : _motionVector(_bits, _zeroVector, 1);
      final period = after.pts - before.pts, offset = header.pts - before.pts;
      if (offset <= 0 || offset >= period)
        throw const FormatException('Invalid MPEG-4 B picture timing');
      final forward = <_Vector>[], backward = <_Vector>[];
      final split = after.motion.split[index] != 0 || picture.volume.quarter;
      for (var block = 0; block < (split ? 4 : 1); block++) {
        final reference = after.motion.at(
          x * 2 + (block & 1),
          y * 2 + (block >> 1),
        );
        final vx = reference.x * offset ~/ period + delta.x;
        final vy = reference.y * offset ~/ period + delta.y;
        forward.add((x: vx, y: vy));
        backward.add((
          x: delta.x != 0
              ? vx - reference.x
              : reference.x * (offset - period) ~/ period,
          y: delta.y != 0
              ? vy - reference.y
              : reference.y * (offset - period) ~/ period,
        ));
      }
      _prediction.predict(picture, before, x, y, forward);
      _prediction.predict(picture, after, x, y, backward, average: true);
    } else {
      final forwards = mode == 1 || mode == 3;
      final backwards = mode == 1 || mode == 2;
      if (forwards) {
        _rowVectors[0] = _motionVector(_bits, _rowVectors[0], _forwardCode);
        _prediction.predict(picture, before, x, y, [_rowVectors[0]]);
      }
      if (backwards) {
        _rowVectors[1] = _motionVector(_bits, _rowVectors[1], _backwardCode);
        _prediction.predict(picture, after, x, y, [
          _rowVectors[1],
        ], average: forwards);
      }
    }
    _readResidual(x, y, pattern);
  }

  void _readResidual(int x, int y, int pattern) {
    for (var block = 0; block < 6; block++) {
      if (pattern & (32 >> block) != 0) {
        _readBlock(x, y, block, coded: true, intra: false);
      }
    }
  }

  _Vector _predictVector(int x, int y, int block) {
    final bx = x * 2 + (block & 1), by = y * 2 + (block >> 1);
    final startX = _sliceStart % _columns;
    final firstLine = y * _columns + x < _sliceStart + _columns;
    final a = picture.motion.at(bx - 1, by);
    final c = picture.motion.at(bx + const [2, 1, 1, -1][block], by - 1);
    if (firstLine && block < 2) {
      if (block == 0 && x == startX) return _zeroVector;
      if (x + 1 == startX) {
        return x == 0 && block == 0 ? c : _medianVector(a, _zeroVector, c);
      }
      return a;
    }
    final b = picture.motion.at(bx, by - 1);
    return _medianVector(
      firstLine && block == 2 && x == startX ? _zeroVector : a,
      b,
      c,
    );
  }
}
