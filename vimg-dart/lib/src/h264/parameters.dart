import 'dart:typed_data';

import '../rbsp.dart';

const _extendedProfiles = {
  44,
  83,
  86,
  100,
  110,
  118,
  122,
  128,
  134,
  135,
  138,
  139,
  144,
  244,
};

typedef H264Color = ({int matrix, bool fullRange});

final class H264Sps {
  H264Sps._({
    required this.id,
    required this.profile,
    required this.level,
    required this.chromaFormat,
    required this.separateColorPlane,
    required this.lumaDepth,
    required this.chromaDepth,
    required this.transformBypass,
    required this.frameNumBits,
    required this.pocType,
    required this.pocLsbBits,
    required this.deltaPocAlwaysZero,
    required this.pocCycle,
    required this.nonReferenceOffset,
    required this.bottomOffset,
    required this.maxReferences,
    required this.allowGaps,
    required this.direct8x8,
    required this.mbWidth,
    required this.mbHeight,
    required this.frameOnly,
    required this.cropLeft,
    required this.cropTop,
    required this.width,
    required this.height,
    required this.color,
    required this.sampleAspect,
    required this.timing,
    required this.scaling,
  });

  factory H264Sps.parse(Uint8List nal) {
    if (nal.isEmpty || nal[0] & 31 != 7)
      throw const FormatException('Expected an H.264 SPS');
    final bits = Rbsp.fromNal(nal);
    final profile = bits.read(8);
    bits.read(8); // constraint flags
    final level = bits.read(8);
    final id = bits.ue(31);
    var chroma = 1;
    var separate = false;
    var lumaDepth = 8, chromaDepth = 8;
    var bypass = false;
    List<H264ScalingList?>? scaling;
    if (_extendedProfiles.contains(profile)) {
      chroma = bits.ue(3);
      separate = chroma == 3 && bits.flag();
      lumaDepth += bits.ue(6);
      chromaDepth += bits.ue(6);
      bypass = bits.flag();
      if (bits.flag()) scaling = readScalingLists(bits, chroma == 3 ? 12 : 8);
    }

    final frameNumBits = bits.ue(12) + 4;
    final pocType = bits.ue(2);
    var pocBits = 0;
    var deltaAlwaysZero = false;
    var pocCycle = const <int>[];
    var nonReferenceOffset = 0, bottomOffset = 0;
    if (pocType == 0) {
      pocBits = bits.ue(12) + 4;
    } else if (pocType == 1) {
      deltaAlwaysZero = bits.flag();
      nonReferenceOffset = bits.se();
      bottomOffset = bits.se();
      final cycle = bits.ue(255);
      pocCycle = List.generate(cycle, (_) => bits.se(), growable: false);
    }
    final maxReferences = bits.ue(16);
    final allowGaps = bits.flag();
    final mbWidth = bits.ue(4095) + 1;
    final mapHeight = bits.ue(4095) + 1;
    final frameOnly = bits.flag();
    if (!frameOnly) bits.bit(); // mb_adaptive_frame_field_flag
    final mbHeight = mapHeight * (frameOnly ? 1 : 2);
    final direct8x8 = bits.flag();
    var left = 0, top = 0, right = 0, bottom = 0;
    if (bits.flag()) {
      final subsampling = separate ? 0 : chroma;
      final cropX = subsampling == 1 || subsampling == 2 ? 2 : 1;
      final cropY = (subsampling == 1 ? 2 : 1) * (frameOnly ? 1 : 2);
      left = bits.ue() * cropX;
      right = bits.ue() * cropX;
      top = bits.ue() * cropY;
      bottom = bits.ue() * cropY;
    }
    final width = 16 * mbWidth - left - right;
    final height = 16 * mbHeight - top - bottom;
    if (width <= 0 || height <= 0)
      throw const FormatException('Invalid H.264 crop');
    final vui = bits.flag() ? _readVui(bits) : null;
    return H264Sps._(
      id: id,
      profile: profile,
      level: level,
      chromaFormat: chroma,
      separateColorPlane: separate,
      lumaDepth: lumaDepth,
      chromaDepth: chromaDepth,
      transformBypass: bypass,
      frameNumBits: frameNumBits,
      pocType: pocType,
      pocLsbBits: pocBits,
      deltaPocAlwaysZero: deltaAlwaysZero,
      pocCycle: pocCycle,
      nonReferenceOffset: nonReferenceOffset,
      bottomOffset: bottomOffset,
      maxReferences: maxReferences,
      allowGaps: allowGaps,
      direct8x8: direct8x8,
      mbWidth: mbWidth,
      mbHeight: mbHeight,
      frameOnly: frameOnly,
      cropLeft: left,
      cropTop: top,
      width: width,
      height: height,
      color: vui?.color ?? (matrix: 2, fullRange: false),
      sampleAspect: vui?.sampleAspect ?? 1,
      timing: vui?.timing,
      scaling: scaling,
    );
  }

  final int id, profile, level, chromaFormat, lumaDepth, chromaDepth;
  final bool separateColorPlane, transformBypass;
  final int frameNumBits, pocType, pocLsbBits;
  final bool deltaPocAlwaysZero;
  final List<int> pocCycle;
  final int nonReferenceOffset, bottomOffset, maxReferences;
  final bool allowGaps, direct8x8;
  final int mbWidth, mbHeight;
  final bool frameOnly;
  final int cropLeft, cropTop, width, height;
  final H264Color color;
  final double sampleAspect;
  final (int, int)? timing; // frame ticks, ticks per second
  final List<H264ScalingList?>? scaling;

  int get chromaHeight => switch (chromaFormat) {
    0 => 0,
    1 => 8,
    _ => 16,
  };

  int get chromaBlockCount => chromaHeight ~/ 2;

  int get lumaQpOffset => 6 * (lumaDepth - 8);
  int get chromaQpOffset => 6 * (chromaDepth - 8);
}

({H264Color color, double sampleAspect, (int, int)? timing}) _readVui(
  Rbsp bits,
) {
  final sampleAspect = bits.readVuiSampleAspect();
  if (bits.flag()) bits.flag(); // overscan
  var fullRange = false;
  var matrix = 2;
  if (bits.flag()) {
    bits.skip(3); // video format
    fullRange = bits.flag();
    if (bits.flag()) {
      bits.skip(16); // color primaries and transfer characteristics
      matrix = bits.read(8);
    }
  }
  if (bits.flag()) {
    bits.ue(); // chroma sample location, top field
    bits.ue(); // chroma sample location, bottom field
  }
  (int, int)? timing;
  if (bits.flag()) {
    final units = bits.read(32), scale = bits.read(32);
    if (units > 0 && scale > 0) timing = (2 * units, scale);
  }
  return (
    color: (matrix: matrix, fullRange: fullRange),
    sampleAspect: sampleAspect,
    timing: timing,
  );
}

final class H264Pps {
  H264Pps._({
    required this.id,
    required this.sps,
    required this.cabac,
    required this.bottomFieldPocPresent,
    required this.activeL0,
    required this.activeL1,
    required this.weightedP,
    required this.weightedB,
    required this.initialQp,
    required this.chromaOffset,
    required this.secondChromaOffset,
    required this.deblockingControl,
    required this.constrainedIntra,
    required this.redundantPicCount,
    required this.transform8x8,
    required this.sliceGroups,
    required this.scaling,
  });

  factory H264Pps.parse(Uint8List nal, Map<int, H264Sps> sequences) {
    if (nal.isEmpty || nal[0] & 31 != 8)
      throw const FormatException('Expected an H.264 PPS');
    final bits = Rbsp.fromNal(nal);
    final id = bits.ue(255);
    final sps = sequences[bits.ue(31)];
    if (sps == null)
      throw const FormatException('H.264 PPS references a missing SPS');
    final cabac = bits.flag();
    final bottomPoc = bits.flag();
    final groups = bits.ue(7) + 1;
    if (groups > 1) _skipSliceGroups(bits, groups);
    final activeL0 = bits.ue(31) + 1;
    final activeL1 = bits.ue(31) + 1;
    final weightedP = bits.flag();
    final weightedB = bits.read(2);
    if (weightedB > 2)
      throw const FormatException('Invalid H.264 weighted_bipred_idc');
    final qp = 26 + bits.se();
    bits.se(); // pic_init_qs_minus26
    final chromaOffset = bits.se();
    final deblocking = bits.flag();
    final constrained = bits.flag();
    final redundant = bits.flag();
    var transform8x8 = false;
    var secondOffset = chromaOffset;
    List<H264ScalingList?>? scaling;
    if (bits.hasMoreData) {
      transform8x8 = bits.flag();
      if (bits.flag()) {
        scaling = readScalingLists(
          bits,
          6 + (transform8x8 ? (sps.chromaFormat == 3 ? 6 : 2) : 0),
        );
      }
      secondOffset = bits.se();
    }
    if (qp < -sps.lumaQpOffset ||
        qp > 51 ||
        chromaOffset < -12 ||
        chromaOffset > 12 ||
        secondOffset < -12 ||
        secondOffset > 12) {
      throw const FormatException('Invalid H.264 picture quantizer');
    }
    return H264Pps._(
      id: id,
      sps: sps,
      cabac: cabac,
      bottomFieldPocPresent: bottomPoc,
      activeL0: activeL0,
      activeL1: activeL1,
      weightedP: weightedP,
      weightedB: weightedB,
      initialQp: qp,
      chromaOffset: chromaOffset,
      secondChromaOffset: secondOffset,
      deblockingControl: deblocking,
      constrainedIntra: constrained,
      redundantPicCount: redundant,
      transform8x8: transform8x8,
      sliceGroups: groups,
      scaling: scaling,
    );
  }

  final int id;
  final H264Sps sps;
  final bool cabac, bottomFieldPocPresent, weightedP;
  final int activeL0, activeL1, weightedB;
  final int initialQp, chromaOffset, secondChromaOffset;
  final bool deblockingControl,
      constrainedIntra,
      redundantPicCount,
      transform8x8;
  final int sliceGroups;
  final List<H264ScalingList?>? scaling;
}

void _skipSliceGroups(Rbsp bits, int count) {
  switch (bits.ue(6)) {
    case 0:
      for (var i = 0; i < count; i++) {
        bits.ue();
      }
    case 2:
      for (var i = 1; i < count; i++) {
        bits.ue();
        bits.ue();
      }
    case 3 || 4 || 5:
      bits.flag();
      bits.ue();
    case 6:
      final size = bits.ue(1 << 22) + 1;
      final width = (count - 1).bitLength;
      bits.skip(size * width);
  }
}

/// A null entry means the standard fallback rule applies. An empty list
/// represents useDefaultScalingMatrixFlag, distinct from a flat matrix.
typedef H264ScalingList = List<int>;

List<H264ScalingList?> readScalingLists(Rbsp bits, int count) => [
  for (var i = 0; i < count; i++)
    if (bits.flag()) _scalingList(bits, i < 6 ? 16 : 64) else null,
];

H264ScalingList _scalingList(Rbsp bits, int count) {
  var last = 8;
  var next = 8;
  final values = <int>[];
  for (var i = 0; i < count; i++) {
    if (next != 0) {
      next = (last + bits.se()) & 255;
      if (i == 0 && next == 0) return const [];
    }
    if (next != 0) last = next;
    values.add(last);
  }
  return values;
}
