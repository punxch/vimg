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
  late final _sac = header.format.arithmetic ? _H263Sac(_bits) : null;
  late final _overlap = header.format.overlapping && reference != null
      ? _H263Overlap(picture, reference!, _motion, _prediction, header)
      : null;
  int _pendingPattern = -1;
  Rbsp get _bits => header.bits;
  int _quant, _sliceStart = 0;

  void decode() {
    final columns = picture.columns;
    final count = columns * picture.rows;
    final overlap = _overlap;
    for (var index = 0; index < count; index++) {
      if (index != 0) _readGroupHeader(index, count);
      final x = index % columns, y = index ~/ columns;
      final mode = _readMacroblock();
      if (mode == -1) {
        if (overlap != null) {
          overlap.markInter(index, _sliceStart);
          _finishOverlap(index - 1);
          _pendingPattern = 0;
        } else {
          _prediction.predict(picture, reference!, x, y, [
            _zeroVector,
          ], noRound: header.noRound);
        }
        continue;
      }
      final intra = header.intra || mode & 4 != 0;
      final aic = intra && header.format.advancedIntra;
      final fromLeft = aic ? _readIntraDirection() : null;
      final cbpy =
          _sac?.read(intra ? _sacIntraPattern : _sacInterPattern) ??
          _lumaPattern.read(_bits);
      final normalPattern =
          intra || header.format.alternateVlc && mode & 3 == 3;
      final pattern = ((normalPattern ? cbpy : cbpy ^ 15) << 2) | (mode & 3);
      if (mode & (header.intra ? 4 : 8) != 0) {
        _readQuantChange();
      }
      if (!intra) {
        final vectors = _readMotion(x, y, mode & 16 != 0);
        if (overlap == null) {
          _prediction.predict(
            picture,
            reference!,
            x,
            y,
            vectors,
            noRound: header.noRound,
          );
        } else {
          overlap.markInter(index, _sliceStart);
        }
      }
      _finishOverlap(index - 1);
      if (overlap != null && !intra) _pendingPattern = pattern;
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
    _finishOverlap(count - 1);
    if (header.format.loopFilter) {
      _deblockH263(
        picture,
        _filterQuant,
        modifiedQuant: header.format.modifiedQuant,
      );
    }
  }

  int _readMacroblock() {
    final sac = _sac;
    if (header.intra) {
      while (true) {
        final code =
            sac?.read(_sacIntraMacroblock) ?? _intraMacroblock.read(_bits);
        if (code != 8) return code;
      }
    }
    final format = header.format;
    final table = header.extended && (format.overlapping || format.loopFilter)
        ? _sacInterMacroblock4mvq
        : _sacInterMacroblock;
    while (true) {
      if (sac == null ? _bits.flag() : sac.read(_sacCod) != 0) return -1;
      if (sac == null) {
        final code = _interMacroblock.read(_bits);
        if (code != 20) return code;
      } else {
        final index = sac.read(table);
        if (index < 20) {
          // Table 8 lists INTER, INTER+Q, INTER4V, INTRA and INTRA+Q.
          const mode = [0, 8, 16, 4, 12];
          return mode[index >> 2] | (index & 3);
        }
        if (index > 20) return index + 3;
      }
    }
  }

  bool? _readIntraDirection() {
    if (_sac case final sac?) {
      final direction = sac.read(_sacIntraMode);
      return direction == 0 ? null : direction == 2;
    }
    return _bits.flag() ? _bits.flag() : null;
  }

  // Delay the previous inter macroblock until its right neighbor's mode
  // and motion vectors are available. Only its six residuals are buffered.
  void _finishOverlap(int index) {
    final pattern = _pendingPattern;
    if (pattern < 0) return;
    final overlap = _overlap!;
    final x = index % picture.columns, y = index ~/ picture.columns;
    overlap.predict(x, y);
    for (var block = 0; block < 6; block++) {
      if (pattern & (32 >> block) != 0) {
        _writeBlock(x, y, block, overlap.residuals[block], intra: false);
      }
    }
    _pendingPattern = -1;
  }

  void _readQuantChange() {
    final quant = !header.format.modifiedQuant
        ? _quant + _quantChange[_sac?.read(_sacQuant) ?? _bits.read(2)]
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
    if (header.format.arithmetic &&
        _bits.remaining >= 5 &&
        _bits.remaining <= 12) {
      final afterStart = _bits.position;
      if (_bits.read(5) == 31 && _bits.read(_bits.remaining) == 0) {
        // Let the last buffered symbols finish before a terminal EOS.
        _bits.position = start;
        return;
      }
      _bits.position = afterStart;
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
    // A SAC interval can reach a future start code while the last
    // buffered macroblocks of the current segment are still being decoded.
    if (header.format.arithmetic && address > index && address < macroblocks) {
      _bits.position = start;
      return;
    }
    if (address != index || quant == 0) {
      throw const FormatException('Invalid H.263 group address or quantizer');
    }
    _quant = quant;
    _sliceStart = index;
    _sac?.reset();
  }

  List<_Vector> _readMotion(int x, int y, bool split) {
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
      if (_sac case final sac?) {
        vector = sac.motion(prediction, header.longVectors);
      } else if (header.format.unrestricted) {
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
    return vectors;
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
      if (_sac case final sac?) {
        values[0] = (sac.read(_sacDc) + 1) * 8;
      } else {
        final dc = _bits.read(8);
        values[0] = (dc == 255 ? 128 : dc) * 8;
      }
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
      if (!_readCoefficients(
        table,
        scan,
        position,
        intra: intra,
        advanced: advanced,
      )) {
        if (!intra && header.format.alternateVlc) {
          _bits.position = start;
          values.fillRange(0, 64, 0);
          if (!_readCoefficients(
            _aicEvents,
            scan,
            position,
            intra: false,
            advanced: false,
          )) {
            throw const FormatException(
              'H.263 alternative VLC run exceeds the block',
            );
          }
        } else {
          throw const FormatException('H.263 run exceeds the block');
        }
      }
    }
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
    if (_pendingPattern >= 0) {
      _overlap!.residuals[block].setAll(0, values);
    } else {
      _writeBlock(x, y, block, values, intra: intra);
    }
  }

  void _writeBlock(
    int x,
    int y,
    int block,
    Int16List values, {
    required bool intra,
  }) {
    final luma = block < 4;
    final plane = luma ? 0 : block - 3;
    final stride = luma ? picture.stride : picture.stride >> 1;
    final bx = luma ? x * 2 + (block & 1) : x;
    final by = luma ? y * 2 + (block >> 1) : y;
    _transform.write(
      picture.planes[plane],
      (by * stride + bx) * 8,
      stride,
      values,
      intra,
    );
  }

  bool _readCoefficients(
    _Events table,
    List<int> scan,
    int position, {
    required bool intra,
    required bool advanced,
  }) {
    var number = 0;
    while (true) {
      final event =
          _sac?.event(number, intra: intra, advanced: advanced) ??
          _readShortEvent(_bits, table, header.sparkEscape);
      position += event.run + 1;
      if (position >= 64) return false;
      _coefficients[scan[position]] = event.value;
      if (event.last) return true;
      if (number < 3) number++;
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
