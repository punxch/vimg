import 'dart:typed_data';

import 'bitstream.dart';

typedef Av1Timing = ({int tickUnits, int timeScale, int? ticksPerPicture});
typedef Av1DecoderModel = ({
  int bufferDelayBits,
  int decodingTickUnits,
  int removalBits,
  int presentationBits,
});
typedef Av1OperatingPoint = ({
  int idc,
  int level,
  bool highTier,
  ({int decoderDelay, int encoderDelay, bool lowDelay})? decoderModel,
  int? displayDelay,
});
typedef Av1FrameIds = ({int bits, int deltaBits});
typedef Av1SequenceTools = ({
  bool superblock128,
  bool filterIntra,
  bool intraEdgeFilter,
  bool interIntra,
  bool maskedCompound,
  bool warpedMotion,
  bool dualFilter,
  bool jointCompound,
  bool referenceMvs,
  int screenContent,
  int integerMv,
  bool superres,
  bool cdef,
  bool restoration,
});

final class Av1ColorConfig {
  const Av1ColorConfig({
    required this.depth,
    required this.monochrome,
    required this.primaries,
    required this.transfer,
    required this.matrix,
    required this.fullRange,
    required this.subsamplingX,
    required this.subsamplingY,
    required this.chromaPosition,
    required this.separateUvDelta,
  });

  factory Av1ColorConfig.read(Av1Bits bits, int profile) {
    final highDepth = bits.flag();
    final depth = !highDepth ? 8 : (profile == 2 && bits.flag() ? 12 : 10);
    final monochrome = profile != 1 && bits.flag();
    final description = bits.flag();
    final primaries = description ? bits.read(8) : 2;
    final transfer = description ? bits.read(8) : 2;
    final matrix = description ? bits.read(8) : 2;
    final identity =
        !monochrome && primaries == 1 && transfer == 13 && matrix == 0;
    final fullRange = identity || bits.flag();
    var x = 0, y = 0, position = 0;
    if (monochrome || (!identity && profile == 0)) {
      x = y = 1;
    } else if (!identity && profile == 2) {
      x = depth == 12 ? bits.read(1) : 1;
      y = depth == 12 && x != 0 ? bits.read(1) : 0;
    }
    if (!monochrome && x != 0 && y != 0) position = bits.read(2);
    if (matrix == 0 && (monochrome || x != 0 || y != 0))
      throw const FormatException('Invalid AV1 identity color subsampling');
    if (identity && (profile == 0 || (profile == 2 && depth != 12)))
      throw const FormatException('Invalid AV1 profile for identity color');
    return Av1ColorConfig(
      depth: depth,
      monochrome: monochrome,
      primaries: primaries,
      transfer: transfer,
      matrix: matrix,
      fullRange: fullRange,
      subsamplingX: x,
      subsamplingY: y,
      chromaPosition: position,
      separateUvDelta: !monochrome && bits.flag(),
    );
  }

  final int depth, primaries, transfer, matrix;
  final int subsamplingX, subsamplingY, chromaPosition;
  final bool monochrome, fullRange, separateUvDelta;

  Object get _signature => (
    depth,
    monochrome,
    primaries,
    transfer,
    matrix,
    fullRange,
    subsamplingX,
    subsamplingY,
    chromaPosition,
    separateUvDelta,
  );

  int get planes => monochrome ? 1 : 3;
}

/// AV1 §5.5.1 sequence, timing and color syntax.
final class Av1SequenceHeader {
  const Av1SequenceHeader._({
    required this.profile,
    required this.still,
    required this.reduced,
    required this.timing,
    required this.decoderModel,
    required this.operatingPoints,
    required this.widthBits,
    required this.heightBits,
    required this.maxWidth,
    required this.maxHeight,
    required this.frameIds,
    required this.orderHintBits,
    required this.tools,
    required this.color,
    required this.filmGrain,
  });

  factory Av1SequenceHeader.read(Uint8List data) {
    final bits = Av1Bits(data);
    final profile = bits.read(3);
    final still = bits.flag(), reduced = bits.flag();
    if (profile > 2 || (reduced && !still))
      throw const FormatException(
        'Invalid AV1 sequence profile or still flags',
      );

    Av1Timing? timing;
    Av1DecoderModel? model;
    final operating = <Av1OperatingPoint>[];
    if (reduced) {
      operating.add((
        idc: 0,
        level: bits.read(5),
        highTier: false,
        decoderModel: null,
        displayDelay: null,
      ));
    } else {
      if (bits.flag()) {
        final units = bits.read(32), scale = bits.read(32);
        final interval = bits.flag() ? bits.uvlc() + 1 : null;
        if (units == 0 || scale == 0 || interval == 0x100000000)
          throw const FormatException('Invalid AV1 sequence timing');
        timing = (
          tickUnits: units,
          timeScale: scale,
          ticksPerPicture: interval,
        );
        if (bits.flag()) {
          model = (
            bufferDelayBits: bits.read(5) + 1,
            decodingTickUnits: bits.read(32),
            removalBits: bits.read(5) + 1,
            presentationBits: bits.read(5) + 1,
          );
          if (model.decodingTickUnits == 0)
            throw const FormatException('Invalid AV1 decoder model timing');
        }
      }
      final initialDelay = bits.flag();
      final count = bits.read(5) + 1;
      for (var i = 0; i < count; i++) {
        final idc = bits.read(12), level = bits.read(5);
        if (idc != 0 && (idc & 255 == 0 || idc & 0xf00 == 0))
          throw const FormatException('Invalid AV1 operating point');
        operating.add((
          idc: idc,
          level: level,
          highTier: level > 7 && bits.flag(),
          decoderModel: model != null && bits.flag()
              ? (
                  decoderDelay: bits.read(model.bufferDelayBits),
                  encoderDelay: bits.read(model.bufferDelayBits),
                  lowDelay: bits.flag(),
                )
              : null,
          displayDelay: initialDelay && bits.flag() ? bits.read(4) + 1 : null,
        ));
      }
    }

    final w = bits.read(4) + 1, h = bits.read(4) + 1;
    final width = bits.read(w) + 1, height = bits.read(h) + 1;
    Av1FrameIds? ids;
    if (!reduced && bits.flag()) {
      final delta = bits.read(4) + 2, total = delta + bits.read(3) + 1;
      if (total > 16) throw const FormatException('Invalid AV1 frame ID size');
      ids = (bits: total, deltaBits: delta);
    }

    final sb128 = bits.flag(), filterIntra = bits.flag(), edge = bits.flag();
    final interIntra = !reduced && bits.flag(),
        masked = !reduced && bits.flag();
    final warp = !reduced && bits.flag(), dual = !reduced && bits.flag();
    final order = !reduced && bits.flag();
    final joint = order && bits.flag(), refMv = order && bits.flag();
    final screen = reduced || bits.flag() ? 2 : bits.read(1);
    final integer = reduced || screen == 0 || bits.flag() ? 2 : bits.read(1);
    final orderBits = order ? bits.read(3) + 1 : 0;
    final superres = bits.flag(), cdef = bits.flag(), restoration = bits.flag();
    final color = Av1ColorConfig.read(bits, profile);
    final grain = bits.flag();
    bits.trailing();
    return Av1SequenceHeader._(
      profile: profile,
      still: still,
      reduced: reduced,
      timing: timing,
      decoderModel: model,
      operatingPoints: List.unmodifiable(operating),
      widthBits: w,
      heightBits: h,
      maxWidth: width,
      maxHeight: height,
      frameIds: ids,
      orderHintBits: orderBits,
      tools: (
        superblock128: sb128,
        filterIntra: filterIntra,
        intraEdgeFilter: edge,
        interIntra: interIntra,
        maskedCompound: masked,
        warpedMotion: warp,
        dualFilter: dual,
        jointCompound: joint,
        referenceMvs: refMv,
        screenContent: screen,
        integerMv: integer,
        superres: superres,
        cdef: cdef,
        restoration: restoration,
      ),
      color: color,
      filmGrain: grain,
    );
  }

  final int profile, widthBits, heightBits, maxWidth, maxHeight, orderHintBits;
  final bool still, reduced, filmGrain;
  final Av1Timing? timing;
  final Av1DecoderModel? decoderModel;
  final List<Av1OperatingPoint> operatingPoints;
  final Av1FrameIds? frameIds;
  final Av1SequenceTools tools;
  final Av1ColorConfig color;

  int get superblockLog2 => tools.superblock128 ? 7 : 6;

  /// §7.5 allows operating buffer parameters to change within a sequence.
  bool sameCodedSequence(Av1SequenceHeader other) {
    if ((
              profile,
              still,
              reduced,
              timing,
              decoderModel,
              widthBits,
              heightBits,
              maxWidth,
              maxHeight,
              frameIds,
              orderHintBits,
              tools,
              filmGrain,
              color._signature,
            ) !=
            (
              other.profile,
              other.still,
              other.reduced,
              other.timing,
              other.decoderModel,
              other.widthBits,
              other.heightBits,
              other.maxWidth,
              other.maxHeight,
              other.frameIds,
              other.orderHintBits,
              other.tools,
              other.filmGrain,
              other.color._signature,
            ) ||
        operatingPoints.length != other.operatingPoints.length)
      return false;

    Object signature(Av1OperatingPoint op) => (
      op.idc,
      op.level,
      op.highTier,
      op.decoderModel != null,
      op.displayDelay,
    );
    for (var i = 0; i < operatingPoints.length; i++) {
      if (signature(operatingPoints[i]) != signature(other.operatingPoints[i]))
        return false;
    }
    return true;
  }

  int relativeDistance(int a, int b) {
    if (orderHintBits == 0) return 0;
    final half = 1 << (orderHintBits - 1);
    return ((a - b + half) & ((half << 1) - 1)) - half;
  }
}

bool av1OperatingLayer(int idc, int temporal, int spatial) =>
    idc == 0 || (idc & (1 << temporal) != 0 && idc & (1 << (spatial + 8)) != 0);
