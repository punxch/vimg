import 'dart:math' as math;

import 'bitstream.dart';
import 'frame_parameters.dart';
import 'sequence_header.dart';
import 'tile_group.dart';

enum Av1FrameType {
  key,
  inter,
  intraOnly,
  switchFrame;

  bool get intra => this == key || this == intraOnly;
}

enum Av1Interpolation { regular, smooth, sharp, bilinear, switchable }

typedef Av1FrameSize = ({
  int width,
  int height,
  int upscaledWidth,
  int renderWidth,
  int renderHeight,
  int superresDenominator,
});
typedef Av1MotionControls = ({
  bool integer,
  bool highPrecision,
  Av1Interpolation interpolation,
  bool switchableMode,
  bool referenceMvs,
  bool compound,
  (int, int)? skipMode,
  bool warped,
});
typedef Av1FrameParameters = ({
  Av1Quantization quantization,
  Av1Segmentation segmentation,
  List<bool> losslessSegments,
  bool codedLossless,
  int? deltaQShift,
  Av1DeltaFilter? deltaFilter,
  Av1LoopFilter loopFilter,
  Av1Cdef? cdef,
  Av1Restoration? restoration,
  Av1TransformMode transformMode,
  bool reducedTransforms,
  List<Av1GlobalMotion> globalMotion,
  Av1FilmGrain? filmGrain,
});

final class Av1FrameHeader {
  const Av1FrameHeader._({
    required this.type,
    required this.showFrame,
    required this.showable,
    required this.errorResilient,
    required this.disableCdfUpdate,
    required this.refreshContext,
    required this.screenContent,
    required this.intrabc,
    required this.frameId,
    required this.orderHint,
    required this.primaryReference,
    required this.references,
    required this.refreshFlags,
    required this.invalidatedSlots,
    required this.size,
    required this.tiles,
    required this.motion,
    required this.parameters,
  });

  final Av1FrameType type;
  final bool showFrame,
      showable,
      errorResilient,
      disableCdfUpdate,
      refreshContext;
  final bool screenContent, intrabc;
  final int frameId, orderHint, refreshFlags, invalidatedSlots;
  final int? primaryReference;
  final List<int> references;
  final Av1FrameSize size;
  final Av1TileLayout tiles;
  final Av1MotionControls motion;
  final Av1FrameParameters parameters;
}

typedef Av1Header = ({
  Av1FrameHeader frame,
  int? existingSlot,
  int? presentationTime,
  Map<int, int> removalTimes,
});

/// AV1 §5.9.2. Read a frame header against the completed reference slots.
Av1Header readAv1FrameHeader(
  Av1Bits bits,
  Av1SequenceHeader seq,
  List<Av1FrameHeader?> slots,
  Av1Obu obu,
) {
  final model = seq.decoderModel, ids = seq.frameIds;
  int? presentation() => model != null && seq.timing?.ticksPerPicture == null
      ? bits.read(model.presentationBits)
      : null;
  if (!seq.reduced && bits.flag()) {
    final index = bits.read(3);
    final time = presentation();
    final id = bits.read(ids?.bits ?? 0);
    final existing = slots[index];
    if (existing == null || !existing.showable || existing.frameId != id)
      throw const FormatException('Unavailable AV1 show-existing frame');
    return (
      frame: existing,
      existingSlot: index,
      presentationTime: time,
      removalTimes: const {},
    );
  }

  final type = seq.reduced
      ? Av1FrameType.key
      : Av1FrameType.values[bits.read(2)];
  final show = seq.reduced || bits.flag();
  final time = show ? presentation() : null;
  final showable = show ? type != Av1FrameType.key : bits.flag();
  final key = type == Av1FrameType.key && show;
  final resilient = key || type == Av1FrameType.switchFrame || bits.flag();
  final disableCdf = bits.flag();
  final tools = seq.tools;
  final screen = tools.screenContent == 2
      ? bits.flag()
      : tools.screenContent == 1;
  final forceInteger =
      screen && (tools.integerMv == 2 ? bits.flag() : tools.integerMv == 1);
  final integer = type.intra || forceInteger;
  final id = bits.read(ids?.bits ?? 0);
  final override =
      type == Av1FrameType.switchFrame || (!seq.reduced && bits.flag());
  final order = bits.read(seq.orderHintBits);
  final primary = type.intra || resilient ? 7 : bits.read(3);
  final removal = <int, int>{};
  if (model != null && bits.flag()) {
    for (final (index, op) in seq.operatingPoints.indexed) {
      if (op.decoderModel != null &&
          av1OperatingLayer(op.idc, obu.temporalId, obu.spatialId))
        removal[index] = bits.read(model.removalBits);
    }
  }

  final refresh = key || type == Av1FrameType.switchFrame ? 255 : bits.read(8);
  if (type == Av1FrameType.intraOnly && refresh == 255)
    throw const FormatException('AV1 intra-only frame refreshes every slot');
  var invalidated = key ? 255 : 0;
  if (ids != null && !key) {
    final mask = (1 << ids.bits) - 1, maximum = 1 << ids.deltaBits;
    for (final (index, prior) in slots.indexed) {
      if (prior != null && ((id - prior.frameId) & mask) > maximum)
        invalidated |= 1 << index;
    }
  }
  final hints = List.generate(8, (i) => slots[i]?.orderHint ?? 0);
  if ((!type.intra || refresh != 255) && resilient && seq.orderHintBits > 0) {
    for (var i = 0; i < 8; i++) {
      final hint = bits.read(seq.orderHintBits);
      if (hint != hints[i]) invalidated |= 1 << i;
      hints[i] = hint;
    }
  }

  Av1FrameHeader reference(int index) {
    final prior = slots[index];
    if (prior == null || invalidated & (1 << index) != 0)
      throw FormatException('Unavailable AV1 reference slot $index');
    return prior;
  }

  final short = !type.intra && seq.orderHintBits > 0 && bits.flag();
  final references = type.intra
      ? const <int>[]
      : short
      ? _shortReferences(seq, order, hints, bits.read(3), bits.read(3))
      : List<int>.filled(7, 0);
  for (var i = 0; i < references.length; i++) {
    if (!short) references[i] = bits.read(3);
    final prior = reference(references[i]);
    if (ids != null) {
      final delta = bits.read(ids.deltaBits) + 1;
      if ((id - delta) & ((1 << ids.bits) - 1) != prior.frameId)
        throw const FormatException('AV1 reference frame ID mismatch');
    }
  }
  final primarySlot = primary == 7 ? null : references[primary];
  final primaryFrame = primarySlot == null ? null : reference(primarySlot);
  final size = _frameSize(
    bits,
    seq,
    override,
    !type.intra && !resilient && override
        ? [for (final slot in references) reference(slot).size]
        : const [],
  );
  final intrabc =
      type.intra && screen && size.superresDenominator == 8 && bits.flag();
  final hp = !type.intra && !integer && bits.flag();
  final interpolation = type.intra
      ? Av1Interpolation.regular
      : bits.flag()
      ? Av1Interpolation.switchable
      : Av1Interpolation.values[bits.read(2)];
  final switchableMode = !type.intra && bits.flag();
  final refMv = !type.intra && !resilient && tools.referenceMvs && bits.flag();
  final refreshContext = !seq.reduced && !disableCdf && !bits.flag();

  final tiles = Av1TileLayout.read(
    bits,
    size.width,
    size.height,
    seq.superblockLog2,
  );
  final quant = readAv1Quantization(bits, seq.color);
  final segmentation = readAv1Segmentation(
    bits,
    primaryFrame?.parameters.segmentation,
  );
  final deltaQ = quant.base > 0 && bits.flag() ? bits.read(2) : null;
  final deltaFilter = deltaQ != null && !intrabc && bits.flag()
      ? (shift: bits.read(2), multi: bits.flag())
      : null;
  final zeroDelta =
      quant.yDc == 0 &&
      quant.uDc == 0 &&
      quant.uAc == 0 &&
      quant.vDc == 0 &&
      quant.vAc == 0;
  final segments = List<bool>.unmodifiable([
    for (final features in segmentation.features)
      zeroDelta && quant.base + (features[0] ?? 0) <= 0,
  ]);
  final lossless = segments.every((lossless) => lossless);
  final chroma = !seq.color.monochrome;
  final filter = !lossless && !intrabc;
  final loop = readAv1LoopFilter(
    bits,
    filter: filter,
    chroma: chroma,
    previous: primaryFrame?.parameters.loopFilter,
  );
  final cdef = readAv1Cdef(bits, filter && tools.cdef, chroma);
  final restoration = readAv1Restoration(
    bits,
    seq,
    tools.restoration &&
        !intrabc &&
        (!lossless || size.superresDenominator != 8),
  );
  final transform = lossless
      ? Av1TransformMode.only4x4
      : bits.flag()
      ? Av1TransformMode.select
      : Av1TransformMode.largest;
  final compound = !type.intra && bits.flag();
  final skip = compound && seq.orderHintBits > 0
      ? _skipMode(seq, order, [for (final slot in references) hints[slot]])
      : null;
  final useSkip = skip != null && bits.flag();
  final warp = !type.intra && !resilient && tools.warpedMotion && bits.flag();
  final reducedTransforms = bits.flag();
  final globalMotion = readAv1GlobalMotion(
    bits,
    type.intra,
    hp,
    primaryFrame?.parameters.globalMotion,
  );
  final grain = readAv1FilmGrain(
    bits,
    seq,
    visible: show || showable,
    inter: type == Av1FrameType.inter,
    fromReference: (index) {
      final source = references.contains(index)
          ? reference(index).parameters.filmGrain
          : null;
      return source ??
          (throw const FormatException('Unavailable AV1 film grain reference'));
    },
  );
  return (
    frame: Av1FrameHeader._(
      type: type,
      showFrame: show,
      showable: showable,
      errorResilient: resilient,
      disableCdfUpdate: disableCdf,
      refreshContext: refreshContext,
      screenContent: screen,
      intrabc: intrabc,
      frameId: id,
      orderHint: order,
      primaryReference: primarySlot,
      references: List.unmodifiable(references),
      refreshFlags: refresh,
      invalidatedSlots: invalidated,
      size: size,
      tiles: tiles,
      motion: (
        integer: integer,
        highPrecision: hp,
        interpolation: interpolation,
        switchableMode: switchableMode,
        referenceMvs: refMv,
        compound: compound,
        skipMode: useSkip ? skip : null,
        warped: warp,
      ),
      parameters: (
        quantization: quant,
        segmentation: segmentation,
        losslessSegments: segments,
        codedLossless: lossless,
        deltaQShift: deltaQ,
        deltaFilter: deltaFilter,
        loopFilter: loop,
        cdef: cdef,
        restoration: restoration,
        transformMode: transform,
        reducedTransforms: reducedTransforms,
        globalMotion: globalMotion,
        filmGrain: grain,
      ),
    ),
    existingSlot: null,
    presentationTime: time,
    removalTimes: Map.unmodifiable(removal),
  );
}

Av1FrameSize _frameSize(
  Av1Bits bits,
  Av1SequenceHeader seq,
  bool override,
  List<Av1FrameSize> references,
) {
  Av1FrameSize? inherited;
  for (final reference in references) {
    if (bits.flag()) {
      inherited = reference;
      break;
    }
  }
  final upscaled =
      inherited?.upscaledWidth ??
      (override ? bits.read(seq.widthBits) + 1 : seq.maxWidth);
  final height =
      inherited?.height ??
      (override ? bits.read(seq.heightBits) + 1 : seq.maxHeight);
  if (upscaled > seq.maxWidth || height > seq.maxHeight)
    throw const FormatException('AV1 frame exceeds sequence dimensions');
  final scale = seq.tools.superres && bits.flag() ? bits.read(3) + 9 : 8;
  final width = math.max(
    math.min(16, upscaled),
    (upscaled * 8 + (scale >> 1)) ~/ scale,
  );
  final separateRenderSize = inherited == null && bits.flag();
  return (
    width: width,
    height: height,
    upscaledWidth: upscaled,
    renderWidth:
        inherited?.renderWidth ??
        (separateRenderSize ? bits.read(16) + 1 : upscaled),
    renderHeight:
        inherited?.renderHeight ??
        (separateRenderSize ? bits.read(16) + 1 : height),
    superresDenominator: scale,
  );
}

List<int> _shortReferences(
  Av1SequenceHeader seq,
  int order,
  List<int> hints,
  int last,
  int golden,
) {
  final distance = [
    for (final hint in hints) seq.relativeDistance(hint, order),
  ];
  if (distance[last] >= 0 || distance[golden] >= 0)
    throw const FormatException(
      'AV1 short reference is outside the forward range',
    );
  final used = 1 << last | 1 << golden;
  final back = <int>[], forward = <int>[];
  for (var slot = 0; slot < 8; slot++) {
    if (used & (1 << slot) == 0)
      (distance[slot] < 0 ? forward : back).add(slot);
  }
  int ascending(int a, int b) {
    final difference = distance[a].compareTo(distance[b]);
    return difference == 0 ? a.compareTo(b) : difference;
  }

  back.sort(ascending);
  forward.sort(ascending);
  final refs = [last, -1, -1, golden, -1, -1, -1];
  if (back.isNotEmpty) refs[6] = back.removeLast();
  if (back.isNotEmpty) refs[4] = back.first;
  if (back.length > 1) refs[5] = back[1];
  final earliest = List.generate(
    8,
    (i) => i,
  ).reduce((a, b) => ascending(a, b) <= 0 ? a : b);
  for (final i in [1, 2, 4, 5, 6]) {
    if (refs[i] < 0)
      refs[i] = forward.isEmpty ? earliest : forward.removeLast();
  }
  return refs;
}

(int, int)? _skipMode(Av1SequenceHeader seq, int order, List<int> hints) {
  final distances = [
    for (final hint in hints) seq.relativeDistance(hint, order),
  ];
  var closestPast = -1, closestFuture = -1;
  for (final (i, distance) in distances.indexed) {
    if (distance < 0 && (closestPast < 0 || distance > distances[closestPast]))
      closestPast = i;
    if (distance > 0 &&
        (closestFuture < 0 || distance < distances[closestFuture]))
      closestFuture = i;
  }
  if (closestPast < 0) return null;
  if (closestFuture < 0) {
    for (final (i, distance) in distances.indexed) {
      if (distance < distances[closestPast] &&
          (closestFuture < 0 || distance > distances[closestFuture])) {
        closestFuture = i;
      }
    }
  }
  if (closestFuture < 0) return null;
  return (
    math.min(closestPast, closestFuture),
    math.max(closestPast, closestFuture),
  );
}
