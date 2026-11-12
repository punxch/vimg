import 'dart:typed_data';

import '../rbsp.dart';
import 'nal.dart';
import 'parameters.dart';
import 'references.dart';

enum HevcSliceKind { b, p, intra }

typedef HevcSliceLongReference = ({int pocLsb, bool used, int? msbCycle});
typedef HevcWeight = ({int weight, int offset});
typedef HevcWeights = ({
  int lumaShift,
  int chromaShift,
  List<List<HevcWeight>> l0,
  List<List<HevcWeight>> l1,
});

final class HevcSliceHeader {
  const HevcSliceHeader({
    required this.nal,
    required this.sps,
    required this.pps,
    required this.first,
    required this.dependent,
    required this.address,
    required this.discardPrior,
    required this.parameters,
    required this.entryLengths,
    required this.bits,
  });

  factory HevcSliceHeader.parse(
    HevcNal nal,
    Map<int, HevcSps> sequences,
    Map<int, HevcPps> pictures, {
    HevcSliceHeader? preceding,
  }) {
    if (!nal.header.codedSlice || nal.header.layer != 0) {
      throw UnsupportedError('Only single-layer HEVC slices are available');
    }
    final bits = nal.rbsp();
    final first = bits.flag();
    final discard = nal.header.irap && bits.flag();
    final pps = pictures[bits.ue(63)];
    if (pps == null)
      throw const FormatException('HEVC slice references a missing PPS');
    final sps = sequences[pps.spsId];
    if (sps == null)
      throw const FormatException('HEVC slice references a missing SPS');
    if (nal.header.temporalId >= sps.temporalLayers ||
        (nal.header.randomAccess && nal.header.temporalId != 0)) {
      throw const FormatException('Invalid HEVC slice temporal layer');
    }
    if ((sps.extensions | pps.extensions) & 0x7f != 0) {
      throw UnsupportedError(
        'HEVC multilayer, 3D and screen-content slice extensions are unavailable',
      );
    }
    final total = sps.ctbWidth * sps.ctbHeight;
    final dependent = !first && pps.dependentSlices && bits.flag();
    final address = first ? 0 : bits.read((total - 1).bitLength);
    if (address >= total || (!first && address == 0)) {
      throw const FormatException('Invalid HEVC slice segment address');
    }
    final HevcSliceParameters parameters;
    if (dependent) {
      if (preceding == null ||
          preceding.pps != pps ||
          preceding.address == address) {
        throw const FormatException(
          'HEVC dependent slice has no preceding slice segment',
        );
      }
      parameters = preceding.parameters;
    } else {
      parameters = HevcSliceParameters._read(bits, nal.header, sps, pps);
    }
    final entries = <int>[];
    if (pps.tiles != null || pps.wavefront) {
      final count = bits.ue(total - 1);
      if (count != 0) {
        final width = bits.ue(31) + 1;
        for (var i = 0; i < count; i++) entries.add(bits.read(width) + 1);
      }
    }
    if (pps.headerExtension) bits.skip(8 * bits.ue(256));
    bits.readStopBit(); // byte_alignment() before the CABAC substreams
    if (bits.remaining < 9)
      throw const FormatException('Missing HEVC slice data');
    return HevcSliceHeader(
      nal: nal.header,
      sps: sps,
      pps: pps,
      first: first,
      dependent: dependent,
      address: address,
      discardPrior: discard,
      parameters: parameters,
      entryLengths: entries,
      bits: bits,
    );
  }

  final HevcNalHeader nal;
  final HevcSps sps;
  final HevcPps pps;
  final bool first, dependent, discardPrior;
  final int address;
  final HevcSliceParameters parameters;

  /// Consecutive substream lengths in EBSP bytes, including prevention bytes.
  final List<int> entryLengths;
  final Rbsp bits;

  /// Split at HEVC entry points while accounting for emulation prevention.
  Iterable<Rbsp> substreams() sync* {
    var start = bits.position >> 3;
    var encodedEnd = start;
    final prevention = bits.preventionOffsets;
    var removed = 0;
    while (removed < prevention.length && prevention[removed] <= encodedEnd) {
      removed++;
      encodedEnd++;
    }
    for (final length in entryLengths) {
      encodedEnd += length;
      while (removed < prevention.length && prevention[removed] < encodedEnd) {
        removed++;
      }
      final end = encodedEnd - removed;
      if (end - start < 2 || end > bits.bytes.length - 2) {
        throw const FormatException('Invalid HEVC slice entry point');
      }
      yield Rbsp(Uint8List.sublistView(bits.bytes, start, end), codec: 'HEVC');
      start = end;
    }
    yield Rbsp(Uint8List.sublistView(bits.bytes, start), codec: 'HEVC');
  }
}

final class HevcSliceParameters {
  const HevcSliceParameters({
    required this.kind,
    required this.output,
    required this.colourPlane,
    required this.pocLsb,
    required this.shortReferences,
    required this.longReferences,
    required this.temporalMvp,
    required this.saoLuma,
    required this.saoChroma,
    required this.activeL0,
    required this.activeL1,
    required this.list0,
    required this.list1,
    required this.mvdL1Zero,
    required this.cabacInit,
    required this.colocatedL0,
    required this.colocatedIndex,
    required this.weights,
    required this.mergeCandidates,
    required this.qp,
    required this.chromaOffsets,
    required this.cuChromaOffset,
    required this.deblockDisabled,
    required this.beta,
    required this.tc,
    required this.filterAcrossSlices,
  });

  factory HevcSliceParameters._read(
    Rbsp bits,
    HevcNalHeader nal,
    HevcSps sps,
    HevcPps pps,
  ) {
    bits.skip(pps.extraHeaderBits);
    final kind = HevcSliceKind.values[bits.ue(2)];
    final output = !pps.outputFlag || bits.flag();
    final plane = sps.separateColourPlane ? bits.read(2) : 0;
    if (plane > 2 || (nal.randomAccess && kind != HevcSliceKind.intra)) {
      throw const FormatException('Invalid HEVC slice type or colour plane');
    }
    var poc = 0;
    var short = const <HevcShortReference>[];
    var long = const <HevcSliceLongReference>[];
    var temporal = false;
    if (!nal.idr) {
      poc = bits.read(sps.pocBits);
      final sets = sps.shortReferences;
      if (bits.flag()) {
        final index = sets.length <= 1
            ? 0
            : bits.read((sets.length - 1).bitLength);
        if (index >= sets.length)
          throw const FormatException('Invalid HEVC short reference set index');
        short = sets[index];
      } else {
        short = readShortReferences(bits, sets, inSlice: true);
      }
      if (sps.longReferences case final stored?) {
        long = _longReferences(bits, sps.pocBits, stored);
      }
      temporal = sps.temporalMvp && bits.flag();
    }
    final saoLuma = sps.sao && bits.flag();
    final saoChroma = sps.sao && sps.chromaArrayType != 0 && bits.flag();
    var l0 = 0, l1 = 0;
    var list0 = const <int>[], list1 = const <int>[];
    var mvdL1Zero = false, init = false, colocatedL0 = true, colocatedIndex = 0;
    var merge = 0;
    HevcWeights? weights;
    if (kind != HevcSliceKind.intra) {
      final bidi = kind == HevcSliceKind.b;
      final override = bits.flag();
      l0 = override ? bits.ue(14) + 1 : pps.activeL0;
      l1 = !bidi ? 0 : (override ? bits.ue(14) + 1 : pps.activeL1);
      final used =
          short.where((r) => r.used).length + long.where((r) => r.used).length;
      if (used == 0)
        throw const FormatException(
          'HEVC inter slice has no reference pictures',
        );
      if (pps.modifyLists && used > 1) {
        list0 = _listIndices(bits, l0, used);
        if (bidi) list1 = _listIndices(bits, l1, used);
      }
      mvdL1Zero = bidi && bits.flag();
      init = pps.cabacInit && bits.flag();
      if (temporal) {
        colocatedL0 = !bidi || bits.flag();
        final count = colocatedL0 ? l0 : l1;
        if (count > 1) colocatedIndex = bits.ue(count - 1);
      }
      if (bidi ? pps.weightedB : pps.weightedP)
        weights = _weights(bits, sps, l0, l1);
      merge = 5 - bits.ue(4);
    }
    final qp = pps.initialQp + bits.se();
    if (qp < -6 * (sps.lumaDepth - 8) || qp > 51)
      throw const FormatException('Invalid HEVC slice quantizer');
    final offsets = pps.sliceChromaOffsets
        ? _readOffsets(bits, pps.chromaOffsets)
        : pps.chromaOffsets;
    final cuOffset =
        pps.rangeExtension?.chromaOffsetDepth != null && bits.flag();
    final deblock = pps.deblock;
    final override = deblock?.canOverride == true && bits.flag();
    final disabled = override ? bits.flag() : deblock?.disabled ?? false;
    final beta = disabled
        ? 0
        : (override ? 2 * _boundedSigned(bits, -6, 6) : deblock?.beta ?? 0);
    final tc = disabled
        ? 0
        : (override ? 2 * _boundedSigned(bits, -6, 6) : deblock?.tc ?? 0);
    final across =
        pps.filterAcrossSlices &&
        (saoLuma || saoChroma || !disabled) &&
        bits.flag();
    return HevcSliceParameters(
      kind: kind,
      output: output,
      colourPlane: plane,
      pocLsb: poc,
      shortReferences: short,
      longReferences: long,
      temporalMvp: temporal,
      saoLuma: saoLuma,
      saoChroma: saoChroma,
      activeL0: l0,
      activeL1: l1,
      list0: list0,
      list1: list1,
      mvdL1Zero: mvdL1Zero,
      cabacInit: init,
      colocatedL0: colocatedL0,
      colocatedIndex: colocatedIndex,
      weights: weights,
      mergeCandidates: merge,
      qp: qp,
      chromaOffsets: offsets,
      cuChromaOffset: cuOffset,
      deblockDisabled: disabled,
      beta: beta,
      tc: tc,
      filterAcrossSlices: across,
    );
  }

  final HevcSliceKind kind;
  final bool output;
  final int colourPlane, pocLsb;
  final List<HevcShortReference> shortReferences;
  final List<HevcSliceLongReference> longReferences;
  final bool temporalMvp, saoLuma, saoChroma;
  final int activeL0, activeL1;
  final List<int> list0, list1;
  final bool mvdL1Zero, cabacInit, colocatedL0;
  final int colocatedIndex;
  final HevcWeights? weights;
  final int mergeCandidates, qp;
  final HevcChromaOffsets chromaOffsets;
  final bool cuChromaOffset, deblockDisabled, filterAcrossSlices;
  final int beta, tc;
}

List<HevcSliceLongReference> _longReferences(
  Rbsp bits,
  int pocBits,
  List<HevcLongReference> stored,
) {
  final reused = stored.isEmpty ? 0 : bits.ue(stored.length);
  final explicit = bits.ue(32 - reused);
  final refs = <HevcSliceLongReference>[];
  var cycle = 0;
  for (var i = 0; i < reused + explicit; i++) {
    final HevcLongReference ref;
    if (i < reused) {
      final index = stored.length == 1
          ? 0
          : bits.read((stored.length - 1).bitLength);
      if (index >= stored.length)
        throw const FormatException('Invalid HEVC long reference index');
      ref = stored[index];
    } else {
      ref = (pocLsb: bits.read(pocBits), used: bits.flag());
    }
    if (i == reused) cycle = 0;
    final hasMsb = bits.flag();
    if (hasMsb) cycle += bits.ue();
    refs.add((
      pocLsb: ref.pocLsb,
      used: ref.used,
      msbCycle: hasMsb ? cycle : null,
    ));
  }
  return refs;
}

List<int> _listIndices(Rbsp bits, int active, int total) {
  if (!bits.flag()) return const [];
  final width = (total - 1).bitLength;
  return List.generate(active, (_) {
    final index = bits.read(width);
    if (index >= total)
      throw const FormatException('Invalid HEVC reference list modification');
    return index;
  });
}

HevcWeights _weights(Rbsp bits, HevcSps sps, int l0, int l1) {
  final hasChroma = sps.chromaArrayType != 0;
  final y = bits.ue(7);
  final c = hasChroma ? y + _boundedSigned(bits, -y, 7 - y) : 0;
  final highPrecision = sps.rangeExtension & 4 != 0;
  final yRange = 1 << (highPrecision ? sps.lumaDepth - 1 : 7);
  final cRange = 1 << (highPrecision ? sps.chromaDepth - 1 : 7);

  List<List<HevcWeight>> readList(int count) {
    final lumaFlags = List.generate(count, (_) => bits.flag());
    final chromaFlags = hasChroma
        ? List.generate(count, (_) => bits.flag())
        : const <bool>[];
    return List.generate(count, (i) {
      final luma = (
        weight: (1 << y) + (lumaFlags[i] ? _boundedSigned(bits, -128, 127) : 0),
        offset: lumaFlags[i] ? _boundedSigned(bits, -yRange, yRange - 1) : 0,
      );
      HevcWeight chroma() {
        if (!hasChroma || !chromaFlags[i]) return (weight: 1 << c, offset: 0);
        final weight = (1 << c) + _boundedSigned(bits, -128, 127);
        final delta = _boundedSigned(bits, -4 * cRange, 4 * cRange - 1);
        return (
          weight: weight,
          offset: (delta + cRange - ((cRange * weight) >> c)).clamp(
            -cRange,
            cRange - 1,
          ),
        );
      }

      return [luma, chroma(), chroma()];
    });
  }

  return (lumaShift: y, chromaShift: c, l0: readList(l0), l1: readList(l1));
}

HevcChromaOffsets _readOffsets(Rbsp bits, HevcChromaOffsets pps) {
  final cb = pps.cb + _boundedSigned(bits, -12, 12);
  final cr = pps.cr + _boundedSigned(bits, -12, 12);
  if (cb.abs() > 12 || cr.abs() > 12)
    throw const FormatException('Invalid HEVC slice chroma offsets');
  return (cb: cb, cr: cr);
}

int _boundedSigned(Rbsp bits, int minimum, int maximum) {
  final value = bits.se();
  if (value < minimum || value > maximum)
    throw const FormatException('HEVC slice field is out of range');
  return value;
}
