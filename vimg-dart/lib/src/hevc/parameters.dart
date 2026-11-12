import '../rbsp.dart';
import 'nal.dart';
import 'references.dart';
import 'scaling_lists.dart';

typedef HevcProfile = ({
  int space,
  bool highTier,
  int id,
  int compatibility,
  int level,
});
typedef HevcBufferLimits = ({int pictures, int reorder, int latency});
typedef HevcColour = ({
  bool fullRange,
  int primaries,
  int transfer,
  int matrix,
});
typedef HevcPcm = ({
  int lumaDepth,
  int chromaDepth,
  int minLog2,
  int maxLog2,
  bool filterDisabled,
});
typedef HevcCrop = ({int left, int top, int right, int bottom});

final class HevcVps {
  const HevcVps(
    this.id,
    this.layers,
    this.temporalLayers,
    this.profile,
    this.bufferLimits,
  );

  factory HevcVps.parse(HevcNal nal) {
    final bits = nal.rbsp();
    final id = bits.read(4);
    bits.skip(2); // base layer flags
    final layers = bits.read(6) + 1;
    final temporalLayers = _temporalLayers(bits);
    bits.skip(1); // temporal nesting
    if (bits.read(16) != 0xffff)
      throw const FormatException('Invalid HEVC VPS reserved bits');
    final profile = _profile(bits, temporalLayers);
    final limits = _bufferLimits(bits, temporalLayers);
    final layerId = bits.read(6);
    final layerSets = bits.ue(1023);
    bits.skip(layerSets * (layerId + 1));
    if (bits.flag()) {
      bits.skip(64); // timing numerator and denominator
      if (bits.flag()) bits.ue(); // ticks per picture order increment
      final hrdCount = bits.ue(layerSets + 1);
      _HrdCommon? previous;
      for (var i = 0; i < hrdCount; i++) {
        bits.ue(layerSets);
        final common = i == 0 || bits.flag();
        previous = _readHrd(bits, temporalLayers, common ? null : previous);
      }
    }
    if (!bits.flag()) _endParameters(bits);
    return HevcVps(id, layers, temporalLayers, profile, limits);
  }

  final int id, layers, temporalLayers;
  final HevcProfile profile;
  final List<HevcBufferLimits> bufferLimits;
}

final class HevcSps {
  const HevcSps({
    required this.id,
    required this.vpsId,
    required this.temporalLayers,
    required this.profile,
    required this.chromaFormat,
    required this.separateColourPlane,
    required this.codedWidth,
    required this.codedHeight,
    required this.crop,
    required this.lumaDepth,
    required this.chromaDepth,
    required this.pocBits,
    required this.bufferLimits,
    required this.minCbLog2,
    required this.ctbLog2,
    required this.minTbLog2,
    required this.maxTbLog2,
    required this.transformDepthInter,
    required this.transformDepthIntra,
    required this.scalingLists,
    required this.amp,
    required this.sao,
    required this.pcm,
    required this.shortReferences,
    required this.longReferences,
    required this.temporalMvp,
    required this.strongIntraSmoothing,
    required this.colour,
    this.sampleAspect = 1,
    required this.fieldSequence,
    required this.timing,
    required this.extensions,
    required this.rangeExtension,
  });

  factory HevcSps.parse(HevcNal nal) {
    final bits = nal.rbsp();
    final vps = bits.read(4);
    final temporalLayers = _temporalLayers(bits);
    bits.skip(1); // temporal nesting
    final profile = _profile(bits, temporalLayers);
    final id = bits.ue(15);
    final chroma = bits.ue(3);
    final separate = chroma == 3 && bits.flag();
    final width = bits.ue(65535), height = bits.ue(65535);
    final crop = _crop(bits, chroma, width, height);
    final lumaDepth = 8 + bits.ue(8), chromaDepth = 8 + bits.ue(8);
    final pocBits = 4 + bits.ue(12);
    final limits = _bufferLimits(bits, temporalLayers);
    final minCb = 3 + bits.ue(3);
    final ctb = minCb + bits.ue(6 - minCb);
    final minTb = 2 + bits.ue(minCb - 2);
    final maxTb = minTb + bits.ue((ctb < 5 ? ctb : 5) - minTb);
    final interDepth = bits.ue(ctb - minTb), intraDepth = bits.ue(ctb - minTb);
    if (minTb >= minCb ||
        ctb < 4 ||
        width % (1 << minCb) != 0 ||
        height % (1 << minCb) != 0) {
      throw const FormatException(
        'Invalid HEVC coding or transform block size',
      );
    }
    final scaling = !bits.flag()
        ? null
        : (bits.flag()
              ? HevcScalingLists.read(bits)
              : const HevcScalingLists.defaults());
    final amp = bits.flag(), sao = bits.flag();
    final HevcPcm? pcm;
    if (bits.flag()) {
      final pcmLuma = bits.read(4) + 1, pcmChroma = bits.read(4) + 1;
      final pcmMin = bits.ue(2) + 3;
      final pcmMax = pcmMin + bits.ue((ctb < 5 ? ctb : 5) - pcmMin);
      pcm = (
        lumaDepth: pcmLuma,
        chromaDepth: pcmChroma,
        minLog2: pcmMin,
        maxLog2: pcmMax,
        filterDisabled: bits.flag(),
      );
    } else {
      pcm = null;
    }
    final shortCount = bits.ue(64);
    final shortRefs = <List<HevcShortReference>>[];
    for (var i = 0; i < shortCount; i++) {
      shortRefs.add(readShortReferences(bits, shortRefs));
    }
    final longRefs = bits.flag()
        ? [
            for (var i = bits.ue(32); i > 0; i--)
              (pocLsb: bits.read(pocBits), used: bits.flag()),
          ]
        : null;
    final temporalMvp = bits.flag();
    final smoothing = bits.flag();
    final vui = bits.flag() ? _readVui(bits, temporalLayers) : null;
    final extensions = bits.flag() ? bits.read(8) : 0;
    final range = extensions & 0x80 != 0 ? bits.read(9) : 0;
    if (extensions & 0x7f == 0) _endParameters(bits);
    return HevcSps(
      id: id,
      vpsId: vps,
      temporalLayers: temporalLayers,
      profile: profile,
      chromaFormat: chroma,
      separateColourPlane: separate,
      codedWidth: width,
      codedHeight: height,
      crop: crop,
      lumaDepth: lumaDepth,
      chromaDepth: chromaDepth,
      pocBits: pocBits,
      bufferLimits: limits,
      minCbLog2: minCb,
      ctbLog2: ctb,
      minTbLog2: minTb,
      maxTbLog2: maxTb,
      transformDepthInter: interDepth,
      transformDepthIntra: intraDepth,
      scalingLists: scaling,
      amp: amp,
      sao: sao,
      pcm: pcm,
      shortReferences: shortRefs,
      longReferences: longRefs,
      temporalMvp: temporalMvp,
      strongIntraSmoothing: smoothing,
      colour: vui?.colour ?? _unspecifiedColour,
      sampleAspect: vui?.sampleAspect ?? 1,
      fieldSequence: vui?.fieldSequence ?? false,
      timing: vui?.timing,
      extensions: extensions,
      rangeExtension: range,
    );
  }

  final int id, vpsId, temporalLayers, chromaFormat;
  final HevcProfile profile;
  final bool separateColourPlane;
  final int codedWidth, codedHeight, lumaDepth, chromaDepth, pocBits;
  final HevcCrop crop;
  final List<HevcBufferLimits> bufferLimits;
  final int minCbLog2, ctbLog2, minTbLog2, maxTbLog2;
  final int transformDepthInter, transformDepthIntra;
  final HevcScalingLists? scalingLists;
  final bool amp, sao;
  final HevcPcm? pcm;
  final List<List<HevcShortReference>> shortReferences;
  final List<HevcLongReference>? longReferences;
  final bool temporalMvp, strongIntraSmoothing, fieldSequence;
  final HevcColour colour;
  final double sampleAspect;
  final (int, int)? timing; // frame ticks, ticks per second
  final int extensions, rangeExtension;

  int get width => codedWidth - crop.left - crop.right;
  int get height => codedHeight - crop.top - crop.bottom;
  int get ctbWidth => (codedWidth + (1 << ctbLog2) - 1) >> ctbLog2;
  int get ctbHeight => (codedHeight + (1 << ctbLog2) - 1) >> ctbLog2;
  int get chromaArrayType => separateColourPlane ? 0 : chromaFormat;
  int get chromaShiftX => chromaArrayType == 1 || chromaArrayType == 2 ? 1 : 0;
  int get chromaShiftY => chromaArrayType == 1 ? 1 : 0;
  bool get intraSmoothingDisabled => rangeExtension & 8 != 0;
  bool get hasUnsupportedRangeTools => rangeExtension & ~8 != 0;
}

typedef HevcTiles = ({List<int> columns, List<int> rows, bool filterAcross});
typedef HevcDeblock = ({bool canOverride, bool disabled, int beta, int tc});
typedef HevcChromaOffsets = ({int cb, int cr});
typedef HevcPpsRange = ({
  int maxTransformSkipLog2,
  bool crossComponent,
  int? chromaOffsetDepth,
  List<HevcChromaOffsets> chromaOffsets,
  int saoLumaScale,
  int saoChromaScale,
});

final class HevcPps {
  const HevcPps({
    required this.id,
    required this.spsId,
    required this.dependentSlices,
    required this.outputFlag,
    required this.extraHeaderBits,
    required this.signHiding,
    required this.cabacInit,
    required this.activeL0,
    required this.activeL1,
    required this.initialQp,
    required this.constrainedIntra,
    required this.transformSkip,
    required this.qpDeltaDepth,
    required this.chromaOffsets,
    required this.sliceChromaOffsets,
    required this.weightedP,
    required this.weightedB,
    required this.transquantBypass,
    required this.tiles,
    required this.wavefront,
    required this.filterAcrossSlices,
    required this.deblock,
    required this.scalingLists,
    required this.modifyLists,
    required this.parallelMergeLog2,
    required this.headerExtension,
    required this.extensions,
    required this.rangeExtension,
  });

  factory HevcPps.parse(HevcNal nal, Map<int, HevcSps> sequences) {
    final bits = nal.rbsp();
    final id = bits.ue(63), spsId = bits.ue(15);
    final sps = sequences[spsId];
    if (sps == null)
      throw const FormatException('HEVC PPS references a missing SPS');
    final dependent = bits.flag(), output = bits.flag();
    final extra = bits.read(3);
    final signHiding = bits.flag(), cabacInit = bits.flag();
    final l0 = bits.ue(14) + 1, l1 = bits.ue(14) + 1;
    final qp = 26 + _signed(bits, -26 - 6 * (sps.lumaDepth - 8), 25);
    final constrained = bits.flag(), skip = bits.flag();
    final deltaDepth = bits.flag()
        ? bits.ue(sps.ctbLog2 - sps.minCbLog2)
        : null;
    final offsets = _chromaOffsets(bits);
    final sliceOffsets = bits.flag(),
        weightedP = bits.flag(),
        weightedB = bits.flag();
    final bypass = bits.flag(), tiled = bits.flag(), wavefront = bits.flag();
    final tiles = tiled ? _readTiles(bits, sps) : null;
    final filterAcrossSlices = bits.flag();
    final deblock = bits.flag() ? _readDeblock(bits) : null;
    final scaling = bits.flag() ? HevcScalingLists.read(bits) : null;
    final modifyLists = bits.flag();
    final mergeLog = 2 + bits.ue(sps.ctbLog2 - 2);
    final headerExtension = bits.flag();
    final extensions = bits.flag() ? bits.read(8) : 0;
    final range = extensions & 0x80 != 0
        ? _readPpsRange(bits, skip, sps)
        : null;
    if (extensions & 0x7f == 0) _endParameters(bits);
    return HevcPps(
      id: id,
      spsId: spsId,
      dependentSlices: dependent,
      outputFlag: output,
      extraHeaderBits: extra,
      signHiding: signHiding,
      cabacInit: cabacInit,
      activeL0: l0,
      activeL1: l1,
      initialQp: qp,
      constrainedIntra: constrained,
      transformSkip: skip,
      qpDeltaDepth: deltaDepth,
      chromaOffsets: offsets,
      sliceChromaOffsets: sliceOffsets,
      weightedP: weightedP,
      weightedB: weightedB,
      transquantBypass: bypass,
      tiles: tiles,
      wavefront: wavefront,
      filterAcrossSlices: filterAcrossSlices,
      deblock: deblock,
      scalingLists: scaling,
      modifyLists: modifyLists,
      parallelMergeLog2: mergeLog,
      headerExtension: headerExtension,
      extensions: extensions,
      rangeExtension: range,
    );
  }

  final int id, spsId, extraHeaderBits;
  final bool dependentSlices, outputFlag, signHiding, cabacInit;
  final int activeL0, activeL1, initialQp;
  final bool constrainedIntra, transformSkip;
  final int? qpDeltaDepth;
  final HevcChromaOffsets chromaOffsets;
  final bool sliceChromaOffsets, weightedP, weightedB, transquantBypass;
  final HevcTiles? tiles;
  final bool wavefront, filterAcrossSlices;
  final HevcDeblock? deblock;
  final HevcScalingLists? scalingLists;
  final bool modifyLists;
  final int parallelMergeLog2;
  final bool headerExtension;
  final int extensions;
  final HevcPpsRange? rangeExtension;
}

HevcTiles _readTiles(Rbsp bits, HevcSps sps) {
  final columns = bits.ue(sps.ctbWidth - 1) + 1;
  final rows = bits.ue(sps.ctbHeight - 1) + 1;
  final uniform = bits.flag();

  List<int> partition(int total, int count) {
    if (uniform) {
      return [
        for (var i = 0; i < count; i++)
          ((i + 1) * total ~/ count) - (i * total ~/ count),
      ];
    }
    final sizes = <int>[];
    var remaining = total;
    for (var i = 0; i < count - 1; i++) {
      final size = bits.ue(remaining - (count - i)) + 1;
      sizes.add(size);
      remaining -= size;
    }
    return [...sizes, remaining];
  }

  return (
    columns: partition(sps.ctbWidth, columns),
    rows: partition(sps.ctbHeight, rows),
    filterAcross: bits.flag(),
  );
}

HevcDeblock _readDeblock(Rbsp bits) {
  final canOverride = bits.flag(), disabled = bits.flag();
  return (
    canOverride: canOverride,
    disabled: disabled,
    beta: disabled ? 0 : 2 * _signed(bits, -6, 6),
    tc: disabled ? 0 : 2 * _signed(bits, -6, 6),
  );
}

HevcPpsRange _readPpsRange(Rbsp bits, bool skip, HevcSps sps) {
  final maxSkip = skip ? bits.ue(sps.maxTbLog2 - 2) + 2 : 2;
  final cross = bits.flag();
  final depth = bits.flag() ? bits.ue(sps.ctbLog2 - sps.minCbLog2) : null;
  final offsets = depth == null
      ? const <HevcChromaOffsets>[]
      : [for (var i = bits.ue(5) + 1; i > 0; i--) _chromaOffsets(bits)];
  return (
    maxTransformSkipLog2: maxSkip,
    crossComponent: cross,
    chromaOffsetDepth: depth,
    chromaOffsets: offsets,
    saoLumaScale: bits.ue(sps.lumaDepth > 10 ? sps.lumaDepth - 10 : 0),
    saoChromaScale: bits.ue(sps.chromaDepth > 10 ? sps.chromaDepth - 10 : 0),
  );
}

HevcChromaOffsets _chromaOffsets(Rbsp bits) =>
    (cb: _signed(bits, -12, 12), cr: _signed(bits, -12, 12));

int _signed(Rbsp bits, int minimum, int maximum) {
  final value = bits.se();
  if (value < minimum || value > maximum)
    throw const FormatException('HEVC signed field is out of range');
  return value;
}

const _unspecifiedColour = (
  fullRange: false,
  primaries: 2,
  transfer: 2,
  matrix: 2,
);

int _temporalLayers(Rbsp bits) {
  final count = bits.read(3) + 1;
  if (count > 7)
    throw const FormatException('Invalid HEVC temporal layer count');
  return count;
}

HevcProfile _profile(Rbsp bits, int layers) {
  final space = bits.read(2), tier = bits.flag(), id = bits.read(5);
  final compatibility = bits.read(32);
  bits.skip(48); // profile constraint indicator flags
  final level = bits.read(8);
  final presence = [for (var i = 1; i < layers; i++) bits.read(2)];
  if (layers > 1) bits.skip((9 - layers) * 2);
  for (final flags in presence) {
    if (flags & 2 != 0) bits.skip(88);
    if (flags & 1 != 0) bits.skip(8);
  }
  return (
    space: space,
    highTier: tier,
    id: id,
    compatibility: compatibility,
    level: level,
  );
}

List<HevcBufferLimits> _bufferLimits(Rbsp bits, int layers) {
  final everyLayer = bits.flag();
  final limits = <HevcBufferLimits>[];
  for (var i = everyLayer ? 0 : layers - 1; i < layers; i++) {
    final count = bits.ue(15) + 1;
    limits.add((
      pictures: count,
      reorder: bits.ue(count - 1),
      latency: bits.ue(),
    ));
  }
  return everyLayer
      ? limits
      : List.filled(layers, limits.single, growable: false);
}

HevcCrop _crop(Rbsp bits, int chroma, int width, int height) {
  if (width == 0 || height == 0)
    throw const FormatException('Invalid HEVC dimensions');
  if (!bits.flag()) return (left: 0, top: 0, right: 0, bottom: 0);
  final xScale = chroma == 1 || chroma == 2 ? 2 : 1;
  final yScale = chroma == 1 ? 2 : 1;
  final left = xScale * bits.ue(width), right = xScale * bits.ue(width);
  final top = yScale * bits.ue(height), bottom = yScale * bits.ue(height);
  if (left + right >= width || top + bottom >= height)
    throw const FormatException('Invalid HEVC conformance window');
  return (left: left, top: top, right: right, bottom: bottom);
}

({
  HevcColour colour,
  bool fieldSequence,
  double sampleAspect,
  (int, int)? timing,
})
_readVui(Rbsp bits, int layers) {
  final sampleAspect = bits.readVuiSampleAspect();
  if (bits.flag()) bits.skip(1); // overscan
  var colour = _unspecifiedColour;
  if (bits.flag()) {
    bits.skip(3); // video format
    final fullRange = bits.flag();
    final described = bits.flag();
    colour = (
      fullRange: fullRange,
      primaries: described ? bits.read(8) : 2,
      transfer: described ? bits.read(8) : 2,
      matrix: described ? bits.read(8) : 2,
    );
  }
  if (bits.flag()) {
    bits.ue(5);
    bits.ue(5);
  }
  bits.skip(1); // neutral chroma
  final field = bits.flag();
  bits.skip(1); // frame field information present
  if (bits.flag()) {
    for (var i = 0; i < 4; i++) bits.ue(); // default display window
  }
  (int, int)? timing;
  if (bits.flag()) {
    final units = bits.read(32), scale = bits.read(32);
    if (units > 0 && scale > 0) timing = (units, scale);
    if (bits.flag()) bits.ue();
    if (bits.flag()) _readHrd(bits, layers, null);
  }
  if (bits.flag()) {
    bits.skip(3);
    for (var i = 0; i < 5; i++) bits.ue();
  }
  return (
    colour: colour,
    fieldSequence: field,
    sampleAspect: sampleAspect,
    timing: timing,
  );
}

typedef _HrdCommon = ({bool nal, bool vcl, bool subPicture});

_HrdCommon _readHrd(Rbsp bits, int layers, _HrdCommon? inherited) {
  final _HrdCommon common;
  if (inherited != null) {
    common = inherited;
  } else {
    final nal = bits.flag(), vcl = bits.flag();
    var subPicture = false;
    if (nal || vcl) {
      subPicture = bits.flag();
      if (subPicture) bits.skip(19);
      bits.skip(8 + (subPicture ? 4 : 0) + 15);
    }
    common = (nal: nal, vcl: vcl, subPicture: subPicture);
  }
  for (var i = 0; i < layers; i++) {
    final fixed = bits.flag() || bits.flag();
    var lowDelay = false;
    if (fixed) {
      bits.ue();
    } else {
      lowDelay = bits.flag();
    }
    final count = lowDelay ? 1 : bits.ue(31) + 1;
    for (final present in [common.nal, common.vcl]) {
      if (!present) continue;
      for (var j = 0; j < count; j++) {
        bits.ue();
        bits.ue();
        if (common.subPicture) {
          bits.ue();
          bits.ue();
        }
        bits.skip(1);
      }
    }
  }
  return common;
}

void _endParameters(Rbsp bits) {
  bits.readStopBit();
  // An Annex B remux can retain trailing_zero_8bits in a parameter-set NAL.
  while (bits.remaining != 0) {
    if (bits.read(8) != 0) {
      throw const FormatException('Unexpected HEVC parameter data');
    }
  }
}
