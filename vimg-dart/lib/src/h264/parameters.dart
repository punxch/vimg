import 'dart:typed_data';

import 'rbsp.dart';

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
    required this.mbWidth,
    required this.mbHeight,
    required this.frameOnly,
    required this.cropLeft,
    required this.cropTop,
    required this.width,
    required this.height,
    required this.color,
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
    if (pocType == 0) {
      pocBits = bits.ue(12) + 4;
    } else if (pocType == 1) {
      deltaAlwaysZero = bits.flag();
      bits.se(); // offset_for_non_ref_pic
      bits.se(); // offset_for_top_to_bottom_field
      final cycle = bits.ue(255);
      for (var i = 0; i < cycle; i++) {
        bits.se();
      }
    }
    bits.ue(16); // max_num_ref_frames
    bits.bit(); // gaps_in_frame_num_value_allowed_flag
    final mbWidth = bits.ue(4095) + 1;
    final mapHeight = bits.ue(4095) + 1;
    final frameOnly = bits.flag();
    if (!frameOnly) bits.bit(); // mb_adaptive_frame_field_flag
    final mbHeight = mapHeight * (frameOnly ? 1 : 2);
    bits.bit(); // direct_8x8_inference_flag
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
    final color = bits.flag()
        ? _readColor(bits)
        : (matrix: 2, fullRange: false);
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
      mbWidth: mbWidth,
      mbHeight: mbHeight,
      frameOnly: frameOnly,
      cropLeft: left,
      cropTop: top,
      width: width,
      height: height,
      color: color,
      scaling: scaling,
    );
  }

  final int id, profile, level, chromaFormat, lumaDepth, chromaDepth;
  final bool separateColorPlane, transformBypass;
  final int frameNumBits, pocType, pocLsbBits;
  final bool deltaPocAlwaysZero;
  final int mbWidth, mbHeight;
  final bool frameOnly;
  final int cropLeft, cropTop, width, height;
  final H264Color color;
  final List<H264ScalingList?>? scaling;
}

H264Color _readColor(Rbsp bits) {
  if (bits.flag() && bits.read(8) == 255) {
    bits.read(16);
    bits.read(16);
  }
  if (bits.flag()) bits.flag(); // overscan
  if (!bits.flag()) return (matrix: 2, fullRange: false);
  bits.read(3); // video format
  final fullRange = bits.flag();
  var matrix = 2;
  if (bits.flag()) {
    bits.read(16); // color primaries and transfer characteristics
    matrix = bits.read(8);
  }
  return (matrix: matrix, fullRange: fullRange);
}

final class H264Pps {
  H264Pps._({
    required this.id,
    required this.sps,
    required this.cabac,
    required this.bottomFieldPocPresent,
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
    bits.ue(31); // default active reference indexes (L0 and L1)
    bits.ue(31);
    bits.read(3); // weighted_pred_flag and weighted_bipred_idc
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
    if (qp < -6 * (sps.lumaDepth - 8) ||
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
  final bool cabac, bottomFieldPocPresent;
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
