part of 'decoder.dart';

final class H263Picture extends _DctPicture {
  H263Picture._(this.format, {bool reduced = false})
    : super(format.width, format.height, alignment: reduced ? 32 : 16);

  final H263Format format;
  Set<_MotionBounds>? _segments;

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

typedef _H263Forward = ({H263Picture picture, int offset, int distance});

/// H.263 pictures and Sorenson Spark use the same macroblock syntax with
/// distinct picture headers and escape codes.
final class H263Decoder {
  H263Decoder({
    bool spark = false,
    H263Format? previous,
    Map<int, H263LayerState>? layers,
    Map<int, Set<int>>? retainedReferences,
  }) : _headers = H263Headers(spark: spark, previous: previous, layers: layers),
       _retainedReferences = retainedReferences;

  final H263Headers _headers;
  final _transform = MpegIdct();
  final _prediction = _Mpeg4MotionCompensation();
  final _references = <int, _H263Reference>{};
  final _olderReferences = <int, _H263Reference>{};
  final Map<int, Set<int>>? _retainedReferences;
  final _history = <int, Map<int, _H263Reference>>{};
  final _erpsBuffers = <int, _H263ErpsBuffer>{};

  H263Picture decode(Uint8List bytes) =>
      decodePair(bytes, includeBidirectional: false).picture!;

  ({H263Picture? picture, H263Picture? bidirectional}) decodePair(
    Uint8List bytes, {
    required bool includeBidirectional,
    bool includeStandaloneB = true,
    bool allowMissingEnhancement = false,
  }) {
    final header = _headers.read(bytes);
    if (header.redundant) return (picture: null, bidirectional: null);
    final format = header.format;
    final referenceLayer = header.bidirectional
        ? header.referenceLayer
        : header.layer;
    final latest = _references[referenceLayer];
    final erps = header.erps == null
        ? null
        : _H263ErpsSelection(
            header,
            _erpsBuffers[referenceLayer] ?? _H263ErpsBuffer(),
            latest,
          );
    if (header.bidirectional) {
      if (!includeStandaloneB) return (picture: null, bidirectional: null);
      final older = _olderReferences[referenceLayer];
      final newest = erps?.picture.backward ?? latest;
      if ((erps == null && older == null) ||
          newest == null ||
          !_h263Matches(newest.picture, format)) {
        throw const FormatException('Missing H.263+ B-picture references');
      }
      final select = erps == null
          ? _forwardSelector(header, older!, following: newest)
          : null;
      final picture = H263Picture._(format, reduced: header.reduced);
      _H263Macroblocks(
        header,
        picture,
        erps?.picture.forward ?? select?.call(header.predictionTemporal),
        _transform,
        _prediction,
        null,
        selectForward: select,
        erps: erps,
      ).decodeB(newest);
      return (
        picture: _h263AlignReference(picture, reduced: false),
        bidirectional: null,
      );
    }
    final picture = H263Picture._(format, reduced: header.reduced);
    final previous = latest;
    if (header.enhancement) {
      final lower = _references[header.referenceLayer];
      if (lower == null ||
          lower.temporal != header.temporalReference ||
          !header.enhancementIntra && previous == null) {
        if (allowMissingEnhancement) {
          _references.remove(header.layer);
          _olderReferences.remove(header.layer);
          _erpsBuffers.remove(header.layer);
          return (picture: null, bidirectional: null);
        }
        throw const FormatException(
          'Missing H.263+ enhancement reference picture',
        );
      }
      final select = header.enhancementIntra || erps != null
          ? null
          : _forwardSelector(header, previous!);
      final blocks = _H263Macroblocks(
        header,
        picture,
        erps?.picture.forward ?? select?.call(header.predictionTemporal),
        _transform,
        _prediction,
        null,
        selectForward: select,
        erps: erps,
      );
      blocks.decodeEnhancement(lower.picture);
      final decoded = _h263AlignReference(picture, reduced: false);
      _saveReference(header, decoded, blocks, erps?.buffer);
      return (picture: decoded, bidirectional: null);
    }
    if (!header.intra && previous == null) {
      throw const FormatException('Missing H.263 reference picture');
    }
    final select = header.intra || erps != null
        ? null
        : _forwardSelector(header, previous!);
    final pb = header.pb == null
        ? null
        : _H263Pb(
            header,
            picture,
            _prediction,
            includeBidirectional
                ? H263Picture._(format, reduced: header.reduced)
                : null,
          );
    final macroblocks = _H263Macroblocks(
      header,
      picture,
      erps?.picture.forward ?? select?.call(header.predictionTemporal),
      _transform,
      _prediction,
      pb,
      selectForward: select,
      erps: erps,
    );
    macroblocks.decode();
    final decoded = _h263AlignReference(picture, reduced: false);
    if (!header.disposable) {
      _saveReference(header, decoded, macroblocks, erps?.buffer);
    }
    return (
      picture: decoded,
      bidirectional: switch (pb?.output) {
        final output? => _h263AlignReference(output, reduced: false),
        null => null,
      },
    );
  }

  _H263Forward Function(int?) _forwardSelector(
    H263Header header,
    _H263Reference previous, {
    _H263Reference? following,
  }) {
    final layer = header.bidirectional ? header.referenceLayer : header.layer;
    final round = following?.resamplingRound ?? header.noRound;
    final pair = header.pb;
    final latestDistance = pair == null
        ? 0
        : h263PbDistance(previous.temporal, header);
    final resolved = <int, _H263Forward>{};
    var resampled = false;
    return (int? temporal) {
      final source = temporal == null || previous.temporal == temporal
          ? previous
          : _history[layer]?[temporal] ??
                (throw FormatException(
                  'Missing H.263 reference picture TR $temporal in layer $layer',
                ));
      return resolved.putIfAbsent(source.temporal, () {
        final warp =
            header.resampling != null ||
            !_h263Matches(source.picture, header.format);
        if ((warp || resampled) && resolved.isNotEmpty) {
          throw const FormatException(
            'H.263 resampling requires one reference picture',
          );
        }
        resampled = warp;
        final int offset, distance;
        if (following != null) {
          (offset: offset, distance: distance) = h263BTiming(
            source.temporal,
            following.temporal,
            header,
          );
        } else if (pair != null) {
          distance = h263TemporalDistance(source.temporal, header);
          offset = pair.offset + distance - latestDistance;
          if (offset <= 0 || offset >= distance) {
            throw const FormatException(
              'Invalid H.263 PB prediction reference',
            );
          }
        } else {
          offset = distance = 0;
        }
        return (
          picture: _h263PredictionReference(source.picture, header, round),
          offset: offset,
          distance: distance,
        );
      });
    };
  }

  void _saveReference(
    H263Header header,
    H263Picture picture,
    _H263Macroblocks blocks,
    _H263ErpsBuffer? erps,
  ) {
    final entry = (
      picture: picture,
      temporal: header.temporalReference,
      resamplingRound: header.layer == 1 && !header.intra
          ? header.noRound
          : null,
      reduced: header.reduced,
      motion: blocks._motion,
      intraWithMotion: blocks._intraWithMotion,
    );
    if (erps != null) {
      erps.save(header.erps!, entry);
      _erpsBuffers[header.layer] = erps;
    } else if (_erpsBuffers.containsKey(header.layer)) {
      if (!header.intra && !header.enhancementIntra) {
        throw const FormatException(
          'H.263+ ERPS may only be disabled in an intra picture',
        );
      }
      _erpsBuffers.remove(header.layer);
    }
    final previous = _references[header.layer];
    if (!_headers.spark && previous != null) {
      _olderReferences[header.layer] = previous;
    }
    _references[header.layer] = entry;
    final keep = _retainedReferences;
    if (erps == null &&
        !_headers.spark &&
        (keep == null ||
            keep[header.layer]?.contains(entry.temporal) == true)) {
      (_history[header.layer] ??= {})[entry.temporal] = entry;
    }
  }
}

bool _h263Matches(H263Picture picture, H263Format format) =>
    picture.width == format.width && picture.height == format.height;

final class _H263Macroblocks {
  _H263Macroblocks(
    this.header,
    this.picture,
    this._forward,
    this._transform,
    this._prediction,
    this._pb, {
    required _H263Forward Function(int?)? selectForward,
    this.erps,
  }) : _selectForward = header.format.referenceSelection ? selectForward : null,
       _motion = _PictureMotion(
         header.macroblockColumns,
         header.macroblockRows,
         false,
       ),
       _quant = header.quant;

  final H263Header header;
  final H263Picture picture;
  _H263Forward? _forward;
  H263Picture? get reference => _forward?.picture;
  final _H263Forward Function(int?)? _selectForward;
  final _H263ErpsSelection? erps;
  _H263Reference? _erpsBackward;

  void _setErpsGroup(H263Erps group) {
    final selection = erps!;
    final resolved = identical(group, header.erps)
        ? selection.picture
        : selection.select(group);
    _forward = resolved.forward;
    _erpsBackward = resolved.backward;
  }

  final MpegIdct _transform;
  final _Mpeg4MotionCompensation _prediction;
  final _H263Pb? _pb;
  final _PictureMotion _motion;
  final _coefficients = Int16List(64);
  late final _columns = header.macroblockColumns;
  late final _rows = header.macroblockRows;
  late final _count = _columns * _rows;
  late final _reducedSamples = header.reduced ? Int16List(64) : null;
  late final _aic = [
    List<_H263IntraBlock?>.filled(_count * 4, null),
    for (var plane = 0; plane < 2; plane++)
      List<_H263IntraBlock?>.filled(_count, null),
  ];
  late final _filterQuant = Uint8List(_count);
  late final _filterSlices =
      header.format.independentSegments ||
          header.reduced && header.format.structured
      ? Uint16List(_count)
      : null;
  Uint16List? _sliceOwners;
  final _segmentBounds = <int, _MotionBounds>{};
  final _validatedReferences = <H263Picture>{};
  late final _preparedSlices = _prepareSlices();
  late final _sac =
      header.format.arithmetic && !header.bidirectional && !header.enhancement
      ? _H263Sac(_bits)
      : null;
  late final _overlap = header.format.overlapping && reference != null
      ? _H263Overlap(picture, _motion, _prediction, header)
      : null;
  H263Picture? _pendingReference;
  int _pendingPattern = -1;
  Uint8List? _intraWithMotion;
  Rbsp get _bits => header.bits;
  int _quant, _sliceStart = 0;

  void decode() {
    final columns = _columns, count = _count;
    final overlap = _overlap;
    var previous = -1;
    for (final index in _macroblockOrder()) {
      final preceding = previous;
      previous = index;
      final x = index % columns, y = index ~/ columns;
      final mode = _readMacroblock();
      if (mode == -1) {
        overlap?.markMotion(index, _sliceStart);
        _finishPrevious(preceding);
        if (overlap != null) {
          _pendingPattern = 0;
          _pendingReference = reference;
        } else {
          _prediction.predictH263(
            picture,
            reference!,
            x,
            y,
            [_zeroVector],
            reduced: header.reduced,
            noRound: header.noRound,
            bounds: _boundsAt(index),
            extend: header.canExtendMotion,
          );
        }
        _pb?.queue(_PbMode.direct, _zeroVector, 0, _forward!);
        continue;
      }
      final intra = header.intra || mode & 4 != 0;
      final aic = intra && header.format.advancedIntra;
      final fromLeft = aic ? _readIntraDirection() : null;
      final pbBlock = _pb == null ? null : _readPbMode();
      final cbpy =
          _sac?.read(intra ? _sacIntraPattern : _sacInterPattern) ??
          _lumaPattern.read(_bits);
      final normalPattern =
          intra || header.format.alternateVlc && mode & 3 == 3;
      final pattern = ((normalPattern ? cbpy : cbpy ^ 15) << 2) | (mode & 3);
      if (mode & (header.intra ? 4 : 8) != 0) {
        _readQuantChange();
      }
      if (!intra || pbBlock?.mode == _PbMode.direct) {
        final vectors = _readMotion(x, y, mode & 16 != 0);
        if (intra) {
          (_intraWithMotion ??= Uint8List(count))[index] = 1;
        }
        if (overlap != null) {
          overlap.markMotion(index, _sliceStart);
        } else if (!intra) {
          _prediction.predictH263(
            picture,
            reference!,
            x,
            y,
            vectors,
            reduced: header.reduced,
            noRound: header.noRound,
            bounds: _boundsAt(index),
            extend: header.canExtendMotion,
          );
        }
      }
      _finishPrevious(preceding);
      if (overlap != null && !intra) {
        _pendingPattern = pattern;
        _pendingReference = reference;
      }
      if (pbBlock != null) {
        final predictor =
            pbBlock.mode == _PbMode.forward && _inCurrentSegment(x - 1, y)
            ? _pb!.leftForward
            : _zeroVector;
        final motion = pbBlock.vector ? _readVector(predictor) : _zeroVector;
        _pb!.queue(pbBlock.mode, motion, pbBlock.pattern, _forward!);
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
      if (pbBlock != null) _readPbBlocks(pbBlock.pattern);
      if (header.reduced || header.format.loopFilter)
        _filterQuant[index] = _quant;
    }
    _finishPrevious(previous);
    _finishFilter();
  }

  void _startMacroblock(int index) {
    if (index != 0) _readGroupHeader(index, _count);
    _filterSlices?[index] = _sliceStart;
  }

  void _finishFilter() {
    if (header.reduced) {
      _filterH263Reduced(
        picture,
        _filterQuant,
        _filterSlices,
        deblock: header.format.loopFilter && !header.bidirectional,
      );
    } else if (header.format.loopFilter && !header.bidirectional) {
      _deblockH263(
        picture,
        _filterQuant,
        modifiedQuant: header.format.modifiedQuant,
        segments: _filterSlices,
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

  // Finish overlapped prediction when the right neighbor's motion is known,
  // then reconstruct the paired B macroblock before P-picture deblocking.
  void _finishPrevious(int index) {
    if (index < 0 || (_pendingPattern < 0 && _pb?.output == null)) return;
    final x = index % _columns, y = index ~/ _columns;
    _finishOverlap(x, y);
    if (_pb?.output != null) {
      _pb!.reconstruct(
        x,
        y,
        _motion,
        _transform,
        _reducedSamples,
        _boundsAt(index),
      );
    }
  }

  void _finishOverlap(int x, int y) {
    final pattern = _pendingPattern;
    if (pattern < 0) return;
    final overlap = _overlap!;
    overlap.predict(x, y, _pendingReference!, _boundsAt(y * _columns + x));
    for (var block = 0; block < 6; block++) {
      if (pattern & (32 >> block) != 0) {
        _writeBlock(x, y, block, overlap.residuals[block], intra: false);
      }
    }
    _pendingPattern = -1;
  }

  ({_PbMode mode, bool vector, int pattern}) _readPbMode() {
    final sac = _sac;
    final improved = header.extended;
    int index;
    if (sac != null) {
      index = sac.read(improved ? _sacImprovedPbMode : _sacPbMode);
    } else {
      index = 0;
      final limit = improved ? 5 : 2;
      while (index < limit && _bits.flag()) {
        index++;
      }
    }
    final hasPattern = improved ? index.isOdd : index == 2;
    var pattern = 0;
    if (hasPattern) {
      if (sac == null) {
        pattern = _bits.read(6);
      } else {
        for (var block = 0; block < 6; block++) {
          pattern =
              (pattern << 1) | sac.read(block < 4 ? _sacPbLuma : _sacPbChroma);
        }
      }
    }
    final mode = improved ? _PbMode.values[index >> 1] : _PbMode.direct;
    return (
      mode: mode,
      vector: improved ? mode == _PbMode.forward : index > 0,
      pattern: pattern,
    );
  }

  void _readPbBlocks(int pattern) {
    final pb = _pb!;
    final bQuant = math.min(31, _quant * header.pb!.quantFactor ~/ 4);
    for (var block = 0; block < 6; block++) {
      if (pattern & (32 >> block) == 0) continue;
      _coefficients.fillRange(0, 64, 0);
      _readTexture(mpegZigzag, -1, intra: false, advanced: false);
      if (pb.output == null) continue;
      final quant = block >= 4 && header.format.modifiedQuant
          ? _h263ChromaQuant[bQuant]
          : bQuant;
      _inverseQuantize(quant, first: 0);
      pb.residuals[block].setAll(0, _coefficients);
    }
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
    if (_sac != null && _bits.remaining >= 5 && _bits.remaining <= 12) {
      final afterStart = _bits.position;
      if (_bits.read(5) == 31 && _bits.read(_bits.remaining) == 0) {
        // Let the last buffered symbols finish before a terminal EOS.
        _bits.position = start;
        return;
      }
      _bits.position = afterStart;
    }
    final group = h263ReadGroupHeader(header, _bits);
    final (:address, :quant, width: _, temporal: _, erps: _) = group;
    // A SAC interval can reach a future start code while the last
    // buffered macroblocks of the current segment are still being decoded.
    if (_sac != null && address > index && address < macroblocks) {
      _bits.position = start;
      return;
    }
    if (address != index || quant == 0) {
      throw const FormatException('Invalid H.263 group address or quantizer');
    }
    _beginGroup(group);
  }

  void _beginGroup(H263GroupHeader group) {
    _quant = group.quant;
    _sliceStart = group.address;
    if (_selectForward case final select?) _forward = select(group.temporal);
    if (group.erps case final erps?) _setErpsGroup(erps);
    _sac?.reset();
  }

  List<_Vector> _readMotion(int x, int y, bool split) {
    final vectors = <_Vector>[];
    for (var i = 0; i < (split ? 4 : 1); i++) {
      final prediction = _h263MotionPrediction(_motion, x, y, i);
      final vector = _readVector(prediction);
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

  _Vector _readVector(_Vector prediction) {
    if (_sac case final sac?) return sac.motion(prediction, header.longVectors);
    if (header.extended && header.format.unrestricted) {
      final (x: dx, y: dy) = h263ReversibleVector(_bits);
      return (x: prediction.x + dx, y: prediction.y + dy);
    }
    return _motionVector(_bits, prediction, 1, long: header.longVectors);
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
      _readTexture(scan, separateDc ? 0 : -1, intra: intra, advanced: advanced);
    }
    final bx = luma ? x * 2 + (block & 1) : x;
    final by = luma ? y * 2 + (block >> 1) : y;
    if (advanced) {
      _reconstructAic(plane, bx, by, quant, fromLeft);
    } else if (coded) {
      _inverseQuantize(quant, first: separateDc ? 1 : 0);
    }
    if (_pendingPattern >= 0) {
      _overlap!.residuals[block].setAll(0, values);
    } else {
      _writeBlock(x, y, block, values, intra: intra);
    }
  }

  void _readTexture(
    List<int> scan,
    int position, {
    required bool intra,
    required bool advanced,
  }) {
    final start = _bits.position;
    final table = advanced ? _aicEvents : _interEvents;
    if (_readCoefficients(
      table,
      scan,
      position,
      intra: intra,
      advanced: advanced,
    )) {
      return;
    }
    if (!intra && header.format.alternateVlc) {
      _bits.position = start;
      _coefficients.fillRange(0, 64, 0);
      if (_readCoefficients(
        _aicEvents,
        scan,
        position,
        intra: false,
        advanced: false,
      )) {
        return;
      }
    }
    throw const FormatException('H.263 run exceeds the block');
  }

  void _inverseQuantize(int quant, {required int first}) {
    final qadd = (quant - 1) | 1;
    for (var i = first; i < 64; i++) {
      final level = _coefficients[i];
      if (level == 0) continue;
      _coefficients[i] = (level.sign * (2 * quant * level.abs() + qadd)).clamp(
        -2048,
        2047,
      );
    }
  }

  void _writeBlock(
    int x,
    int y,
    int block,
    Int16List values, {
    required bool intra,
  }) {
    _writeH263Block(
      _transform,
      picture,
      x,
      y,
      block,
      values,
      intra,
      _reducedSamples,
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

void _writeH263Block(
  MpegIdct transform,
  H263Picture picture,
  int x,
  int y,
  int block,
  Int16List values,
  bool intra,
  Int16List? reducedSamples,
) {
  final luma = block < 4;
  final plane = luma ? 0 : block - 3;
  final stride = luma ? picture.stride : picture.stride >> 1;
  final bx = luma ? x * 2 + (block & 1) : x;
  final by = luma ? y * 2 + (block >> 1) : y;
  final pixels = picture.planes[plane];
  if (reducedSamples == null) {
    transform.write(pixels, (by * stride + bx) * 8, stride, values, intra);
  } else {
    transform.samples(values, reducedSamples);
    _writeH263ReducedBlock(
      pixels,
      (by * stride + bx) * 16,
      stride,
      reducedSamples,
      intra,
    );
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
