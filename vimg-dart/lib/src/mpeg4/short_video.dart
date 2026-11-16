part of 'decoder.dart';

final class H263Picture extends _DctPicture {
  H263Picture._(this.format) : super(format.width, format.height);

  final H263Format format;

  image.Image rgb({YuvImageScaler? scaler}) => yuvImage(
    y: planes[0],
    cb: planes[1],
    cr: planes[2],
    stride: stride,
    chromaStride: stride >> 1,
    width: width,
    height: height,
    cropLeft: 0,
    cropTop: 0,
    matrix: 6,
    fullRange: false,
    sampleAspect: format.aspect,
    scaler: scaler,
  );
}

/// H.263 pictures and Sorenson Spark use the same macroblock syntax with
/// distinct picture headers and escape codes.
final class H263Decoder {
  H263Decoder({bool spark = false, H263Format? previous})
    : _headers = H263Headers(spark: spark, previous: previous);

  final H263Headers _headers;
  final _transform = MpegIdct();
  final _prediction = _Mpeg4MotionCompensation();
  H263Picture? _reference;

  H263Picture decode(Uint8List bytes) {
    final header = _headers.read(bytes);
    final format = header.format;
    if (format.overlapping) {
      throw UnsupportedError('H.263 overlapped motion compensation');
    }
    final picture = H263Picture._(format);
    final reference = header.intra ? null : _reference;
    if (!header.intra &&
        (reference == null ||
            reference.width != picture.width ||
            reference.height != picture.height)) {
      throw const FormatException('Missing H.263 reference picture');
    }
    _H263Macroblocks(
      header,
      picture,
      reference,
      _transform,
      _prediction,
    ).decode();
    if (!header.disposable) _reference = picture;
    return picture;
  }
}

final class _H263Macroblocks {
  _H263Macroblocks(
    this.header,
    this.picture,
    this.reference,
    this._transform,
    this._prediction,
  ) : _motion = _PictureMotion(picture.columns, picture.rows, false),
      _quant = header.quant;

  final H263Header header;
  final H263Picture picture;
  final H263Picture? reference;
  final MpegIdct _transform;
  final _Mpeg4MotionCompensation _prediction;
  final _PictureMotion _motion;
  final _coefficients = Int16List(64);
  late final _aic = [
    List<_H263IntraBlock?>.filled(picture.columns * picture.rows * 4, null),
    for (var plane = 0; plane < 2; plane++)
      List<_H263IntraBlock?>.filled(picture.columns * picture.rows, null),
  ];
  late final _filterQuant = Uint8List(picture.columns * picture.rows);
  Rbsp get _bits => header.bits;
  int _quant, _sliceStart = 0;

  void decode() {
    final columns = picture.columns;
    final count = columns * picture.rows;
    for (var index = 0; index < count; index++) {
      if (index != 0) _readGroupHeader(index, count);
      final x = index % columns, y = index ~/ columns;
      final int mode;
      if (header.intra) {
        var code = _intraMacroblock.read(_bits);
        while (code == 8) {
          code = _intraMacroblock.read(_bits);
        }
        mode = code;
      } else {
        var code = 20;
        while (code == 20) {
          if (_bits.flag()) {
            code = -1;
          } else {
            code = _interMacroblock.read(_bits);
          }
        }
        mode = code;
      }
      if (mode == -1) {
        _prediction.predict(picture, reference!, x, y, [
          _zeroVector,
        ], noRound: header.noRound);
        continue;
      }
      final intra = header.intra || mode & 4 != 0;
      final aic = intra && header.format.advancedIntra;
      final fromLeft = aic && _bits.flag() ? _bits.flag() : null;
      final cbpy = _lumaPattern.read(_bits);
      final normalPattern =
          intra || header.format.alternateVlc && mode & 3 == 3;
      final pattern = ((normalPattern ? cbpy : cbpy ^ 15) << 2) | (mode & 3);
      if (mode & (header.intra ? 4 : 8) != 0) {
        _readQuantChange();
      }
      if (!intra) {
        _predict(x, y, mode & 16 != 0);
      }
      for (var block = 0; block < 6; block++) {
        final coded = pattern & (32 >> block) != 0;
        if (intra || coded) {
          _readBlock(
            x,
            y,
            block,
            intra: intra,
            coded: coded,
            advanced: aic,
            fromLeft: fromLeft,
          );
        }
      }
      if (header.format.loopFilter) _filterQuant[index] = _quant;
    }
    if (header.format.loopFilter) {
      _deblockH263(
        picture,
        _filterQuant,
        modifiedQuant: header.format.modifiedQuant,
      );
    }
  }

  void _readQuantChange() {
    final quant = !header.format.modifiedQuant
        ? _quant + _quantChange[_bits.read(2)]
        : _bits.flag()
        ? _h263QuantChange[_bits.bit()][_quant]
        : _bits.read(5);
    _quant = quant.clamp(1, 31);
  }

  void _readGroupHeader(int index, int macroblocks) {
    if (_bits.remaining < 29) return;
    final start = _bits.position;
    if (_bits.read(16) != 0) {
      _bits.position = start;
      return;
    }
    var padding = 0;
    while (!_bits.flag()) {
      if (++padding > 15)
        throw const FormatException('Invalid H.263 GOB start');
    }
    final int address, quant;
    if (header.format.structured) {
      h263Marker(_bits);
      address = _bits.read(h263AddressBits(macroblocks));
      if (macroblocks > 1583) h263Marker(_bits);
      quant = _bits.read(5);
      h263Marker(_bits);
      _bits.skip(2); // group frame identifier
    } else {
      final group = _bits.read(5);
      final groupRows = picture.height <= 400
          ? 1
          : picture.height <= 800
          ? 2
          : 4;
      address = group * picture.columns * groupRows;
      _bits.skip(2);
      quant = _bits.read(5);
    }
    if (address != index || quant == 0) {
      throw const FormatException('Invalid H.263 group address or quantizer');
    }
    _quant = quant;
    _sliceStart = index;
  }

  void _predict(int x, int y, bool split) {
    final vectors = <_Vector>[];
    for (var i = 0; i < (split ? 4 : 1); i++) {
      final prediction = _motionPrediction(
        _motion,
        picture.columns,
        _sliceStart,
        x,
        y,
        i,
        h263: true,
      );
      final _Vector vector;
      if (header.format.unrestricted) {
        final dx = _readUmv(), dy = _readUmv();
        if (dx == 1 && dy == 1) h263Marker(_bits);
        vector = (x: prediction.x + dx, y: prediction.y + dy);
      } else {
        vector = _motionVector(_bits, prediction, 1, long: header.longVectors);
      }
      vectors.add(vector);
      if (split) _motion.store(x, y, i, vector);
    }
    if (!split) {
      for (var i = 0; i < 4; i++) {
        _motion.store(x, y, i, vectors.single);
      }
    }
    _prediction.predict(
      picture,
      reference!,
      x,
      y,
      vectors,
      noRound: header.noRound,
    );
  }

  int _readUmv() {
    if (_bits.flag()) return 0;
    var value = 2 + _bits.bit();
    while (_bits.flag()) {
      value = (value << 1) | _bits.bit();
      if (value >= 32768)
        throw const FormatException('Oversized H.263 motion difference');
    }
    return value.isOdd ? -(value >> 1) : value >> 1;
  }

  void _readBlock(
    int x,
    int y,
    int block, {
    required bool intra,
    required bool coded,
    required bool advanced,
    required bool? fromLeft,
  }) {
    final values = _coefficients..fillRange(0, 64, 0);
    final separateDc = intra && !advanced;
    if (separateDc) {
      final dc = _bits.read(8);
      values[0] = (dc == 255 ? 128 : dc) * 8;
    }
    final luma = block < 4;
    final plane = luma ? 0 : block - 3;
    final quant = !luma && header.format.modifiedQuant
        ? _h263ChromaQuant[_quant]
        : _quant;
    if (coded) {
      final scan = switch (fromLeft) {
        true => verticalScan,
        false => horizontalScan,
        null => mpegZigzag,
      };
      final start = _bits.position;
      final position = separateDc ? 0 : -1;
      final table = advanced ? _aicEvents : _interEvents;
      if (!_readCoefficients(table, scan, position)) {
        if (!intra && header.format.alternateVlc) {
          _bits.position = start;
          values.fillRange(0, 64, 0);
          if (!_readCoefficients(_aicEvents, scan, position)) {
            throw const FormatException(
              'H.263 alternative VLC run exceeds the block',
            );
          }
        } else {
          throw const FormatException('H.263 run exceeds the block');
        }
      }
    }
    final stride = luma ? picture.stride : picture.stride >> 1;
    final bx = luma ? x * 2 + (block & 1) : x;
    final by = luma ? y * 2 + (block >> 1) : y;
    if (advanced) {
      _reconstructAic(plane, bx, by, quant, fromLeft);
    } else if (coded) {
      final qadd = (quant - 1) | 1;
      for (var i = separateDc ? 1 : 0; i < 64; i++) {
        final level = values[i];
        if (level == 0) continue;
        values[i] = (level.sign * (2 * quant * level.abs() + qadd)).clamp(
          -2048,
          2047,
        );
      }
    }
    _transform.write(
      picture.planes[plane],
      (by * stride + bx) * 8,
      stride,
      values,
      intra,
    );
  }

  bool _readCoefficients(_Events table, List<int> scan, int position) {
    while (true) {
      final event = _readShortEvent(_bits, table, header.sparkEscape);
      position += event.run + 1;
      if (position >= 64) return false;
      _coefficients[scan[position]] = event.value;
      if (event.last) return true;
    }
  }
}

_DctEvent _readShortEvent(Rbsp bits, _Events table, bool spark) {
  final code = table._vlc.read(bits);
  if (code < table._runs.length) {
    final level = table._levels[code];
    return (
      run: table._runs[code],
      value: bits.flag() ? -level : level,
      last: code >= table._firstLast,
    );
  }
  final size = spark ? (bits.flag() ? 11 : 7) : 8;
  final last = bits.flag();
  final run = bits.read(6);
  var value = _readSigned(bits, size);
  if (!spark && value == -128) {
    final low = bits.read(5);
    value = _readSigned(bits, 6) * 32 + low;
  }
  if (value == 0) throw const FormatException('Invalid H.263 escape level');
  return (run: run, value: value, last: last);
}

int _readSigned(Rbsp bits, int size) {
  final value = bits.read(size);
  return value & (1 << (size - 1)) == 0 ? value : value - (1 << size);
}
