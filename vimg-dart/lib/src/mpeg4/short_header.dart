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

typedef H263Resampling = ({
  int precisionBits,
  List<({int x, int y})> parameters,
  ({int y, int cb, int cr})? fill,
});

const H263Resampling h263ImplicitResampling = (
  precisionBits: 4,
  parameters: [(x: 0, y: 0), (x: 0, y: 0), (x: 0, y: 0), (x: 0, y: 0)],
  fill: null,
);

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
  int layer,
  int referenceLayer,
  bool bidirectional,
  bool enhancementIntra,
  H263Resampling? resampling,
  ({int offset, int quantFactor})? pb,
  Rbsp bits,
});

extension H263PictureLayer on H263Header {
  bool get enhancement => layer > 1 && !bidirectional;
}

typedef H263LayerState = ({H263Format format, int? lowerLayer, int bReference});

final class H263Headers {
  H263Headers({
    this.spark = false,
    H263Format? previous,
    Map<int, H263LayerState>? layers,
  }) : _extended = previous,
       _layers = {...?layers};

  final bool spark;
  H263Format? _extended;
  final Map<int, H263LayerState> _layers;
  final _references = <int, ({H263Format format, H263Resampling? warp})>{};

  Map<int, H263LayerState>? snapshotLayers() =>
      _layers.isEmpty ? null : Map.of(_layers);

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
    var layer = 1, referenceLayer = 1;
    var bidirectional = false, enhancementIntra = false;
    H263Resampling? resampling;
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
      if (type > 5) throw UnsupportedError('H.263+ picture type $type');
      intra = type == 0;
      paired = type == 2;
      final explicitResampling = bits.flag();
      if (bits.flag())
        throw UnsupportedError('H.263+ reduced-resolution update');
      noRound = bits.flag();
      bits.skip(3); // reserved MPPTYPE bits
      _checkMultipoint(bits);
      bidirectional = type == 3;
      enhancementIntra = type == 4;
      final layered = type >= 3;
      format = options != null
          ? _readFormat(bits, options)
          : layered
          ? _inheritedLayerFormat(bits, allowBase: bidirectional)
          : _extended ?? (throw const FormatException('Missing H.263+ format'));
      longVectors = false;
      if (format.customClock) temporal |= bits.read(2) << 8;
      if (options != null) {
        if (format.unrestricted && !bits.flag()) bits.skip(1);
        if (format.structured && bits.read(2) != 0)
          throw UnsupportedError('H.263+ rectangular or unordered slices');
      }
      if (layered) {
        layer = bits.read(4);
        if (layer == 0 || layer == 1 && !bidirectional) {
          throw const FormatException('Invalid H.263+ enhancement layer');
        }
        final previous = _layers[layer];
        referenceLayer = options != null
            ? bits.read(4)
            : bidirectional
            ? previous?.bReference ?? layer
            : previous?.lowerLayer ?? 0;
        if (referenceLayer < 1 ||
            referenceLayer > layer ||
            !bidirectional && referenceLayer == layer) {
          throw const FormatException('Invalid H.263+ reference layer');
        }
        if (layer > 1) {
          _layers[layer] = (
            format: format,
            lowerLayer: bidirectional ? previous?.lowerLayer : referenceLayer,
            bReference: bidirectional ? referenceLayer : layer,
          );
        }
      }
      if (options != null && layer == 1) {
        _extended = format;
      }
      if (explicitResampling) {
        if (intra || enhancementIntra) {
          throw const FormatException(
            'Invalid H.263+ intra reference resampling',
          );
        }
        resampling = _readResampling(
          bits,
          format,
          lowerLayer: type == 5 ? referenceLayer : null,
        );
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
    if (!bidirectional) _references[layer] = (format: format, warp: resampling);
    return (
      format: format,
      temporalReference: temporal,
      intra: intra,
      disposable: bidirectional,
      quant: quant,
      noRound: noRound,
      longVectors: longVectors,
      sparkEscape: false,
      extended: source >= 6,
      layer: layer,
      referenceLayer: referenceLayer,
      bidirectional: bidirectional,
      enhancementIntra: enhancementIntra,
      resampling: resampling,
      pb: pb,
      bits: bits,
    );
  }

  H263Resampling _readResampling(
    Rbsp bits,
    H263Format format, {
    required int? lowerLayer,
  }) {
    final precisionBits = switch (bits.read(2)) {
      2 => 1,
      3 => 4,
      _ => throw const FormatException('Invalid H.263+ resampling accuracy'),
    };
    if (lowerLayer != null) {
      final lower = _references[lowerLayer];
      final lowerFormat =
          lower?.format ??
          (lowerLayer == 1 ? _extended : _layers[lowerLayer]?.format);
      if (lowerFormat == null) {
        throw const FormatException(
          'Missing H.263+ resampling reference layer',
        );
      }
      final warp = lower?.warp ?? h263ImplicitResampling;
      final horizontal = format.width == 2 * lowerFormat.width;
      final vertical = format.height == 2 * lowerFormat.height;
      return (
        precisionBits: precisionBits,
        parameters: [
          for (final (x: x, y: y) in warp.parameters)
            (
              x: horizontal ? 2 * x + bits.bit() : x,
              y: vertical ? 2 * y + bits.bit() : y,
            ),
        ],
        fill: warp.fill,
      );
    }
    final parameters = [
      for (var i = 0; i < 4; i++) h263ReversibleVector(bits, maximum: 4095),
    ];
    final fill = switch (bits.read(2)) {
      0 => _readFillColor(bits),
      1 => (y: 16, cb: 128, cr: 128),
      2 => (y: 128, cb: 128, cr: 128),
      _ => null,
    };
    return (precisionBits: precisionBits, parameters: parameters, fill: fill);
  }

  H263Format _inheritedLayerFormat(Rbsp bits, {required bool allowBase}) {
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
      final candidate = layer == 1 && allowBase ? base : _layers[layer]?.format;
      if (candidate != null && candidate.customClock == custom) {
        return candidate;
      }
    }
    throw const FormatException('Missing H.263+ layer format');
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
      layer: 1,
      referenceLayer: 1,
      bidirectional: false,
      enhancementIntra: false,
      resampling: null,
      pb: null,
      bits: bits,
    );
  }
}

({int y, int cb, int cr}) _readFillColor(Rbsp bits) {
  final y = bits.read(8);
  h263Marker(bits);
  final cb = bits.read(8);
  h263Marker(bits);
  return (y: y, cb: cb, cr: bits.read(8));
}

({int x, int y}) h263ReversibleVector(Rbsp bits, {int maximum = 16383}) {
  final x = _readReversibleComponent(bits, maximum);
  final y = _readReversibleComponent(bits, maximum);
  if (x == 1 && y == 1) h263Marker(bits);
  return (x: x, y: y);
}

int _readReversibleComponent(Rbsp bits, int maximum) {
  if (bits.flag()) return 0;
  var value = 2 + bits.bit();
  while (bits.flag()) {
    value = (value << 1) | bits.bit();
    if ((value >> 1) > maximum) {
      throw const FormatException('Oversized H.263 reversible VLC value');
    }
  }
  return value.isOdd ? -(value >> 1) : value >> 1;
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
