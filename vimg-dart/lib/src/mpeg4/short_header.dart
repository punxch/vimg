import 'dart:typed_data';

import '../rbsp.dart';

const _standardSize = [
  (0, 0),
  (128, 96),
  (176, 144),
  (352, 288),
  (704, 576),
  (1408, 1152),
];

typedef H263Format = ({
  int width,
  int height,
  double aspect,
  int tickNumerator,
  int tickDenominator,
  bool customClock,
  bool unrestricted,
  bool overlapping,
  bool arithmetic,
  bool advancedIntra,
  bool loopFilter,
  bool structured,
  bool alternateVlc,
  bool modifiedQuant,
});

typedef H263Header = ({
  H263Format format,
  int temporalReference,
  bool intra,
  bool disposable,
  int quant,
  bool noRound,
  bool longVectors,
  bool sparkEscape,
  bool extended,
  int? temporalLayer,
  ({int offset, int quantFactor})? pb,
  Rbsp bits,
});

final class H263Headers {
  H263Headers({
    this.spark = false,
    H263Format? previous,
    Map<int, H263Format>? temporalLayers,
  }) : _extended = previous,
       _temporalLayers = {...?temporalLayers};

  final bool spark;
  H263Format? _extended;
  final Map<int, H263Format> _temporalLayers;

  Map<int, H263Format>? snapshotTemporalLayers() =>
      _temporalLayers.isEmpty ? null : Map.of(_temporalLayers);

  H263Header read(Uint8List bytes) {
    final bits = Rbsp(bytes, codec: spark ? 'Sorenson Spark' : 'H.263');
    if (spark) return _readSpark(bits);
    if (bits.read(22) != 0x20)
      throw const FormatException('Invalid H.263 picture start');
    var temporal = bits.read(8);
    if (bits.read(2) != 2) throw const FormatException('Invalid H.263 PTYPE');
    bits.skip(3); // split-screen, document camera, freeze release
    final source = bits.read(3);
    final bool intra, longVectors, noRound, paired;
    final H263Format format;
    final int quant;
    int? temporalLayer;
    if (source < 6) {
      intra = !bits.flag();
      longVectors = bits.flag();
      final arithmetic = bits.flag();
      final overlapping = bits.flag();
      paired = bits.flag();
      quant = bits.read(5);
      _checkMultipoint(bits);
      final (width, height) = _standardSize[source];
      format = _basicFormat(
        width,
        height,
        12 / 11,
        unrestricted: longVectors,
        overlapping: overlapping,
        arithmetic: arithmetic,
      );
      _extended = format;
      noRound = false;
    } else {
      final update = bits.read(3);
      if (update > 1) throw const FormatException('Invalid H.263+ UFEP');
      final options = update == 1 ? _readOptions(bits) : null;
      final type = bits.read(3);
      if (type > 3) throw UnsupportedError('H.263+ picture type $type');
      intra = type == 0;
      paired = type == 2;
      if (bits.read(2) != 0)
        throw UnsupportedError('H.263+ resampled reference or scaled update');
      noRound = bits.flag();
      bits.skip(3); // reserved MPPTYPE bits
      _checkMultipoint(bits);
      final bidirectional = type == 3;
      format = options != null
          ? _readFormat(bits, options)
          : bidirectional
          ? _inheritedBFormat(bits)
          : _extended ?? (throw const FormatException('Missing H.263+ format'));
      longVectors = false;
      if (format.customClock) temporal |= bits.read(2) << 8;
      if (options != null) {
        if (format.unrestricted && !bits.flag()) bits.skip(1);
        if (format.structured && bits.read(2) != 0)
          throw UnsupportedError('H.263+ rectangular or unordered slices');
      }
      if (bidirectional) {
        temporalLayer = bits.read(4);
        if (temporalLayer == 0) {
          throw const FormatException('Invalid H.263+ enhancement layer');
        }
        if (options != null) {
          final referenceLayer = bits.read(4);
          if (referenceLayer != 1) {
            throw UnsupportedError(
              'H.263+ external B-picture reference layer $referenceLayer',
            );
          }
          if (temporalLayer > 1) _temporalLayers[temporalLayer] = format;
        }
      }
      if (options != null && (temporalLayer == null || temporalLayer == 1)) {
        _extended = format;
      }
      quant = bits.read(5);
    }
    _checkPicture(format, quant);
    if (paired && intra)
      throw const FormatException('Invalid H.263 PB picture type');
    final pb = paired
        ? (
            offset: bits.read(format.customClock ? 5 : 3),
            quantFactor: 5 + bits.read(2),
          )
        : null;
    if (pb?.offset == 0)
      throw const FormatException('Invalid H.263 B-picture time');
    while (bits.flag()) bits.skip(8);
    if (format.structured) {
      h263Marker(bits);
      final count = ((format.width + 15) >> 4) * ((format.height + 15) >> 4);
      if (bits.read(h263AddressBits(count)) != 0)
        throw const FormatException('H.263+ picture starts mid-slice');
      h263Marker(bits);
    }
    return (
      format: format,
      temporalReference: temporal,
      intra: intra,
      disposable: temporalLayer != null,
      quant: quant,
      noRound: noRound,
      longVectors: longVectors,
      sparkEscape: false,
      extended: source >= 6,
      temporalLayer: temporalLayer,
      pb: pb,
      bits: bits,
    );
  }

  H263Format _inheritedBFormat(Rbsp bits) {
    final position = bits.position;
    final base = _extended;
    // ETR precedes ELNUM. A previously signalled layer supplies the
    // width of ETR; prefer the base-layer clock if both alignments fit.
    final preferred = base?.customClock ?? false;
    for (final custom in [preferred, !preferred]) {
      if (bits.remaining < (custom ? 6 : 4)) continue;
      if (custom) bits.skip(2);
      final layer = bits.read(4);
      bits.position = position;
      final candidate = layer == 1 ? base : _temporalLayers[layer];
      if (candidate != null && candidate.customClock == custom) {
        return candidate;
      }
    }
    throw const FormatException('Missing H.263+ B-picture layer format');
  }

  H263Header _readSpark(Rbsp bits) {
    if (bits.read(17) != 1)
      throw const FormatException('Invalid Sorenson Spark picture start');
    final version = bits.read(5);
    if (version > 1)
      throw const FormatException('Invalid Spark bitstream version');
    final temporal = bits.read(8), source = bits.read(3);
    final (width, height) = switch (source) {
      0 => (bits.read(8), bits.read(8)),
      1 => (bits.read(16), bits.read(16)),
      2 => (352, 288),
      3 => (176, 144),
      4 => (128, 96),
      5 => (320, 240),
      6 => (160, 120),
      _ => (0, 0),
    };
    final type = bits.read(2);
    if (type == 3) throw const FormatException('Invalid Spark picture type');
    bits.skip(1); // deblocking hint for display
    final quant = bits.read(5);
    final format = _basicFormat(width, height, 1);
    _checkPicture(format, quant);
    while (bits.flag()) bits.skip(8);
    return (
      format: format,
      temporalReference: temporal,
      intra: type == 0,
      disposable: type == 2,
      quant: quant,
      noRound: false,
      longVectors: false,
      sparkEscape: version == 1,
      extended: false,
      temporalLayer: null,
      pb: null,
      bits: bits,
    );
  }
}

int h263TemporalDistance(int previous, H263Header header) =>
    (header.temporalReference - previous) %
    (header.format.customClock ? 1024 : 256);

({int offset, int distance}) h263BTiming(
  int previous,
  int following,
  H263Header header,
) {
  final wrap = header.format.customClock ? 1024 : 256;
  final offset = (header.temporalReference - previous) % wrap;
  final distance = (following - previous) % wrap;
  if (offset == 0 || offset >= distance) {
    throw const FormatException('H.263+ B-picture lies outside its references');
  }
  return (offset: offset, distance: distance);
}

int h263PbDistance(int previous, H263Header header) {
  final distance = h263TemporalDistance(previous, header);
  if (header.pb!.offset >= distance) {
    throw const FormatException('H.263 B-picture lies outside its references');
  }
  return distance;
}

H263Format _basicFormat(
  int width,
  int height,
  double aspect, {
  bool unrestricted = false,
  bool overlapping = false,
  bool arithmetic = false,
}) => (
  width: width,
  height: height,
  aspect: aspect,
  tickNumerator: 1001,
  tickDenominator: 30000,
  customClock: false,
  unrestricted: unrestricted,
  overlapping: overlapping,
  arithmetic: arithmetic,
  advancedIntra: false,
  loopFilter: false,
  structured: false,
  alternateVlc: false,
  modifiedQuant: false,
);

typedef _Options = ({
  int source,
  bool customClock,
  bool unrestricted,
  bool overlapping,
  bool arithmetic,
  bool advancedIntra,
  bool loopFilter,
  bool structured,
  bool alternateVlc,
  bool modifiedQuant,
});

_Options _readOptions(Rbsp bits) {
  final source = bits.read(3);
  final customClock = bits.flag(), unrestricted = bits.flag();
  final arithmetic = bits.flag();
  final overlapping = bits.flag(), aic = bits.flag(), loop = bits.flag();
  final structured = bits.flag();
  if (bits.read(2) != 0)
    throw UnsupportedError(
      'H.263+ reference selection or independent segments',
    );
  final alternate = bits.flag(), modified = bits.flag();
  if (arithmetic && (unrestricted || alternate || modified)) {
    throw const FormatException('Incompatible H.263+ arithmetic coding modes');
  }
  if (bits.read(4) != 8) throw const FormatException('Invalid H.263+ OPPTYPE');
  return (
    source: source,
    customClock: customClock,
    unrestricted: unrestricted,
    overlapping: overlapping,
    arithmetic: arithmetic,
    advancedIntra: aic,
    loopFilter: loop,
    structured: structured,
    alternateVlc: alternate,
    modifiedQuant: modified,
  );
}

H263Format _readFormat(Rbsp bits, _Options options) {
  final source = options.source;
  final int width, height;
  final double aspect;
  if (source == 6) {
    final aspectCode = bits.read(4);
    width = (bits.read(9) + 1) * 4;
    h263Marker(bits);
    height = bits.read(9) * 4;
    if (aspectCode == 15) {
      final w = bits.read(8), h = bits.read(8);
      aspect = w == 0 || h == 0 ? 1 : w / h;
    } else {
      aspect = switch (aspectCode) {
        2 => 12 / 11,
        3 => 10 / 11,
        4 => 16 / 11,
        5 => 40 / 33,
        _ => 1,
      };
    }
  } else {
    if (source > 5) throw const FormatException('Invalid H.263+ source format');
    (width, height) = _standardSize[source];
    aspect = 12 / 11;
  }
  final numerator = options.customClock
      ? (1000 + bits.bit()) * bits.read(7)
      : 1001;
  final denominator = options.customClock ? 1800000 : 30000;
  if (numerator == 0)
    throw const FormatException('Invalid H.263+ picture clock');
  return (
    width: width,
    height: height,
    aspect: aspect,
    tickNumerator: numerator,
    tickDenominator: denominator,
    customClock: options.customClock,
    unrestricted: options.unrestricted,
    overlapping: options.overlapping,
    arithmetic: options.arithmetic,
    advancedIntra: options.advancedIntra,
    loopFilter: options.loopFilter,
    structured: options.structured,
    alternateVlc: options.alternateVlc,
    modifiedQuant: options.modifiedQuant,
  );
}

int h263AddressBits(int macroblocks) {
  if (macroblocks <= 48) return 6;
  if (macroblocks <= 99) return 7;
  if (macroblocks <= 396) return 9;
  if (macroblocks <= 1584) return 11;
  if (macroblocks <= 6336) return 13;
  return 14;
}

void h263Marker(Rbsp bits) {
  if (!bits.flag()) throw const FormatException('Missing H.263 marker bit');
}

void _checkMultipoint(Rbsp bits) {
  if (bits.flag())
    throw UnsupportedError('H.263 continuous presence multipoint');
}

void _checkPicture(H263Format format, int quant) {
  if (format.width == 0 ||
      format.height == 0 ||
      format.width * format.height > 64 * 1024 * 1024 ||
      quant == 0) {
    throw const FormatException('Invalid H.263 dimensions or quantizer');
  }
}
