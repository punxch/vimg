import 'dart:math' as math;
import 'dart:typed_data';

import '../mpeg12/syntax.dart' show mpegStartCodes, mpegZigzag;
import '../rbsp.dart';
import 'tables.dart';

part 'sprite.dart';

enum Mpeg4PictureType { intra, predictive, bidirectional, sprite }

typedef Mpeg4Signal = ({int matrix, bool fullRange});
const _defaultSignal = (matrix: 6, fullRange: false);

class Mpeg4Volume {
  Mpeg4Volume._(
    this.width,
    this.height,
    this.resolution,
    this.incrementBits,
    this.fixedIncrement,
    this.aspect,
    this.signal,
    this.interlaced,
    this.quarter,
    this.sprite,
    this.resync,
    this.partitioned,
    this.reversibleVlc,
    this.quantBits,
    this.intraMatrix,
    this.interMatrix,
    this.complexityIntra,
    this.complexityPredictive,
    this.complexityBidirectional,
  );

  final int width, height, resolution, incrementBits;
  final int? fixedIncrement;
  final double aspect;
  final Mpeg4Signal signal;
  final bool interlaced, quarter, resync, partitioned, reversibleVlc;
  final Mpeg4Sprite? sprite;
  final int quantBits;
  final List<int>? intraMatrix, interMatrix;
  final int complexityIntra, complexityPredictive, complexityBidirectional;

  static Mpeg4Volume read(Rbsp bits, Mpeg4Signal signal) {
    bits.skip(1); // random accessible VOL
    final object = bits.read(8);
    if (object == 14 || object == 15)
      throw UnsupportedError('MPEG-4 Studio profile');
    final hasIdentifier = bits.flag();
    final version = hasIdentifier ? bits.read(4) : 1;
    if (hasIdentifier) bits.skip(3);
    final aspectCode = bits.read(4);
    final double aspect;
    if (aspectCode == 15) {
      final width = bits.read(8), height = bits.read(8);
      aspect = width > 0 && height > 0 ? width / height : 1;
    } else {
      aspect = switch (aspectCode) {
        2 => 12 / 11,
        3 => 10 / 11,
        4 => 16 / 11,
        5 => 40 / 33,
        _ => 1,
      };
    }
    if (bits.flag()) {
      if (bits.read(2) != 1) throw UnsupportedError('MPEG-4 non-4:2:0 chroma');
      bits.skip(1); // low_delay
      if (bits.flag()) {
        for (final length in [15, 15, 15, 14, 15]) {
          bits.skip(length);
          mpeg4Marker(bits);
        }
      }
    }
    if (bits.read(2) != 0)
      throw UnsupportedError('MPEG-4 nonrectangular object');
    mpeg4Marker(bits);
    final resolution = bits.read(16);
    if (resolution == 0)
      throw const FormatException('Missing MPEG-4 VOP time resolution');
    final incrementBits = math.max(1, (resolution - 1).bitLength);
    mpeg4Marker(bits);
    final increment = bits.flag() ? bits.read(incrementBits) : null;
    mpeg4Marker(bits);
    final width = bits.read(13);
    mpeg4Marker(bits);
    final height = bits.read(13);
    mpeg4Marker(bits);
    if (width == 0 || height == 0 || width * height > 64 * 1024 * 1024) {
      throw const FormatException('Invalid MPEG-4 dimensions');
    }
    final interlaced = bits.flag();
    if (!bits.flag())
      throw UnsupportedError('MPEG-4 overlapped motion compensation');
    final spriteUsage = bits.read(version == 1 ? 1 : 2);
    if (spriteUsage == 1) throw UnsupportedError('MPEG-4 static sprites');
    if (spriteUsage == 3)
      throw const FormatException('Invalid MPEG-4 sprite usage');
    final sprite = spriteUsage == 2 ? Mpeg4Sprite.read(bits) : null;
    var quantBits = 5;
    if (bits.flag()) {
      quantBits = bits.read(4);
      if (bits.read(4) != 8 || quantBits < 3 || quantBits > 9) {
        throw UnsupportedError('MPEG-4 nonstandard quantizer precision');
      }
    }
    List<int>? intra, inter;
    if (bits.flag()) {
      intra = bits.flag() ? _matrix(bits) : mpeg4IntraMatrix;
      inter = bits.flag() ? _matrix(bits) : mpeg4InterMatrix;
    }
    final quarter = version != 1 && bits.flag();
    var complexityI = 0, complexityP = 0, complexityB = 0;
    if (!bits.flag()) {
      final method = bits.read(2);
      if (method > 1)
        throw const FormatException('Invalid MPEG-4 complexity method');
      if (!bits.flag()) {
        for (var i = 0; i < 6; i++) {
          complexityI += 8 * bits.bit();
        }
      }
      if (!bits.flag()) {
        complexityI += 8 * bits.bit();
        complexityP += 8 * bits.bit();
        complexityP += 8 * bits.bit();
        complexityI += 8 * bits.bit();
      }
      mpeg4Marker(bits);
      if (!bits.flag()) {
        for (final length in [8, 8, 8, 4]) {
          complexityI += length * bits.bit();
        }
      }
      if (!bits.flag()) {
        complexityP += 8 * bits.bit();
        complexityP += 8 * bits.bit();
        complexityB += 8 * bits.bit();
        for (var i = 0; i < 3; i++) {
          complexityP += 8 * bits.bit();
        }
      }
      mpeg4Marker(bits);
      if (method == 1) {
        complexityI += 8 * bits.bit();
        complexityP += 8 * bits.bit();
      }
    }
    final resync = !bits.flag();
    final partitioned = bits.flag();
    final reversibleVlc = partitioned && bits.flag();
    if (version != 1) {
      if (bits.flag()) throw UnsupportedError('MPEG-4 NEWPRED');
      if (bits.flag()) throw UnsupportedError('MPEG-4 reduced resolution VOP');
    }
    if (bits.flag())
      throw UnsupportedError('MPEG-4 temporal or spatial scalability');
    return Mpeg4Volume._(
      width,
      height,
      resolution,
      incrementBits,
      increment,
      aspect,
      signal,
      interlaced,
      quarter,
      sprite,
      resync,
      partitioned,
      reversibleVlc,
      quantBits,
      intra,
      inter,
      complexityI,
      complexityP,
      complexityB,
    );
  }
}

List<int> _matrix(Rbsp bits) {
  final matrix = List<int>.filled(64, 0);
  var last = 0, finished = false;
  for (final index in mpegZigzag) {
    final value = finished ? 0 : bits.read(8);
    if (value == 0) {
      if (last == 0)
        throw const FormatException('Empty MPEG-4 quantization matrix');
      finished = true;
    } else {
      last = value;
    }
    matrix[index] = last;
  }
  return matrix;
}

typedef Mpeg4Vop = ({
  Mpeg4PictureType type,
  Mpeg4Volume volume,
  int pts,
  bool coded,
  bool noRound,
  Mpeg4Gmc? globalMotion,
  bool topFieldFirst,
  int? fieldInterval,
  bool alternateScan,
  int dcThreshold,
  int quant,
  int forwardCode,
  int backwardCode,
  Rbsp bits,
});

typedef Mpeg4Clock = ({
  int base,
  int? reference,
  int? fieldInterval,
  bool legacySprite,
});

typedef Mpeg4CodedVop = ({
  Mpeg4Vop header,
  int offset,
  int length,
  Uint8List? configuration,
  Mpeg4Clock clock,
});

/// Tracks the VOL and VOP clock in coded order, including B pictures.
final class Mpeg4Headers {
  Mpeg4Volume? volume;
  Uint8List? configuration;
  Mpeg4Signal _signal = _defaultSignal;
  Uint8List? _visualObject;
  var _base = 0, _previousBase = 0;
  int? _lastReference, _previousReference, _fieldInterval;
  bool _legacySprite = false;

  Mpeg4Clock get clock => (
    base: _base,
    reference: _lastReference,
    fieldInterval: _fieldInterval,
    legacySprite: _legacySprite,
  );

  void restoreClock(Mpeg4Clock clock) {
    _base = clock.base;
    _lastReference = clock.reference;
    _fieldInterval = clock.fieldInterval;
    _legacySprite = clock.legacySprite;
  }

  Iterable<Mpeg4CodedVop> read(Uint8List bytes) sync* {
    var start = 0;
    for (final unit in mpegStartCodes(bytes)) {
      final snapshot = clock;
      final header = readUnit(
        unit.code,
        Uint8List.sublistView(bytes, unit.data, unit.end),
      );
      if (header != null) {
        yield (
          header: header,
          offset: start,
          length: unit.end - start,
          configuration: configuration,
          clock: snapshot,
        );
        start = unit.end;
      }
    }
  }

  /// Advances the clock from the bytes after one start code.
  Mpeg4Vop? readUnit(int code, Uint8List payload, {bool timingOnly = false}) {
    final bits = Rbsp(payload, codec: 'MPEG-4 Visual');
    if (code == 0xb5) {
      _signal = _readSignal(bits);
      _visualObject = Uint8List.fromList([0, 0, 1, code, ...payload]);
    } else if (code >= 0x20 && code <= 0x2f) {
      final current = Mpeg4Volume.read(bits, _signal);
      if (volume != null && volume!.resolution != current.resolution) {
        _base = _previousBase = 0;
        _lastReference = _previousReference = null;
      }
      _fieldInterval = null;
      volume = current;
      configuration = Uint8List.fromList([
        ...?_visualObject,
        0,
        0,
        1,
        code,
        ...payload,
      ]);
    } else if (code == 0xb2 && payload.length >= 4) {
      final name = String.fromCharCodes(
        payload,
        0,
        math.min(payload.length, 24),
      );
      if (name.startsWith('DivX')) {
        _legacySprite = _divxSpriteMarker.hasMatch(name);
      }
    } else if (code == 0xb3) {
      final hours = bits.read(5), minutes = bits.read(6);
      mpeg4Marker(bits);
      _base = hours * 3600 + minutes * 60 + bits.read(6);
    } else if (code == 0xb6) {
      final layer =
          volume ?? (throw const FormatException('Missing MPEG-4 VOL header'));
      return _readVop(bits, layer, timingOnly);
    }
    return null;
  }

  Mpeg4Vop _readVop(Rbsp bits, Mpeg4Volume layer, bool timingOnly) {
    final type = Mpeg4PictureType.values[bits.read(2)];
    var seconds = 0;
    while (bits.flag()) {
      seconds++;
      if (seconds > 65535)
        throw const FormatException('Oversized MPEG-4 VOP timestamp');
    }
    mpeg4Marker(bits);
    final increment = bits.read(layer.incrementBits);
    if (increment >= layer.resolution)
      throw const FormatException('Invalid MPEG-4 VOP increment');
    mpeg4Marker(bits);
    final coded = bits.flag();
    final bidirectional = type == Mpeg4PictureType.bidirectional;
    if (!bidirectional) {
      _previousBase = _base;
      _base += seconds;
    }
    final whole = bidirectional ? _previousBase + seconds : _base;
    final pts = whole * layer.resolution + increment;
    var noRound = false, topFieldFirst = false, alternate = false;
    var threshold = 0, quant = 1, forward = 1, backward = 1;
    Mpeg4Gmc? globalMotion;
    if (coded) {
      if (!bidirectional) {
        _previousReference = _lastReference;
        _lastReference = pts;
      } else if (_previousReference case final previous?
          when layer.interlaced && _fieldInterval == null) {
        // Field-direct temporal scaling uses the first B-VOP's lead over
        // its past reference after the VOL.
        if (pts > previous && pts < _lastReference!) {
          _fieldInterval = pts - previous;
        }
      }
    }
    if (coded && !timingOnly) {
      final usesGmc = type == Mpeg4PictureType.sprite;
      noRound = (type == Mpeg4PictureType.predictive || usesGmc) && bits.flag();
      bits.skip(
        layer.complexityIntra +
            (type == Mpeg4PictureType.intra ? 0 : layer.complexityPredictive) +
            (bidirectional ? layer.complexityBidirectional : 0),
      );
      threshold = mpeg4DcThreshold[bits.read(3)];
      if (layer.interlaced) {
        topFieldFirst = bits.flag();
        alternate = bits.flag();
      }
      if (usesGmc) {
        globalMotion = Mpeg4Gmc.read(bits, layer, legacyDivx: _legacySprite);
      }
      quant = bits.read(layer.quantBits);
      if (type != Mpeg4PictureType.intra) forward = bits.read(3);
      if (bidirectional) backward = bits.read(3);
      if (quant == 0 || forward == 0 || backward == 0) {
        throw const FormatException(
          'Invalid MPEG-4 VOP quantizer or motion range',
        );
      }
    }
    return (
      type: type,
      volume: layer,
      pts: pts,
      coded: coded,
      noRound: noRound,
      globalMotion: globalMotion,
      topFieldFirst: topFieldFirst,
      fieldInterval: _fieldInterval,
      alternateScan: alternate,
      dcThreshold: threshold,
      quant: quant,
      forwardCode: forward,
      backwardCode: backward,
      bits: bits,
    );
  }
}

Mpeg4Signal _readSignal(Rbsp bits) {
  if (bits.flag()) bits.skip(7);
  final type = bits.read(4);
  if (type != 1 || !bits.flag()) return _defaultSignal;
  bits.skip(3); // video_format
  final range = bits.flag();
  if (!bits.flag()) return (matrix: 6, fullRange: range);
  bits.skip(16); // primaries and transfer
  final matrix = bits.read(8);
  return (matrix: matrix == 2 ? 6 : matrix, fullRange: range);
}

void mpeg4Marker(Rbsp bits) {
  if (!bits.flag()) throw const FormatException('Missing MPEG-4 marker bit');
}
