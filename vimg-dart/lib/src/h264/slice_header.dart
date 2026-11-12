import 'dart:typed_data';

import 'parameters.dart';
import 'rbsp.dart';

enum SliceKind { p, b, intra }

typedef ReferenceModification = ({int op, int value});
typedef ReferenceMarking = ({int op, int first, int second});
typedef PredictionWeight = ({int weight, int offset});

final class PredictionWeights {
  const PredictionWeights(this.lumaShift, this.chromaShift, this.l0, this.l1);

  factory PredictionWeights.read(
    Rbsp bits,
    H264Sps sps,
    int activeL0,
    int activeL1,
  ) {
    final lumaShift = bits.ue(7);
    final hasChroma = sps.chromaFormat != 0;
    final chromaShift = hasChroma ? bits.ue(7) : 0;
    final lumaDefault = (weight: 1 << lumaShift, offset: 0);
    final chromaDefault = (weight: 1 << chromaShift, offset: 0);

    List<List<PredictionWeight>> readList(int count) => [
      for (var i = 0; i < count; i++)
        [
          bits.flag() ? _weight(bits) : lumaDefault,
          if (hasChroma && bits.flag()) ...[
            _weight(bits),
            _weight(bits),
          ] else ...[
            chromaDefault,
            chromaDefault,
          ],
        ],
    ];
    return PredictionWeights(
      lumaShift,
      chromaShift,
      readList(activeL0),
      readList(activeL1),
    );
  }

  final int lumaShift, chromaShift;
  final List<List<PredictionWeight>> l0, l1;
}

PredictionWeight _weight(Rbsp bits) {
  final weight = bits.se(), offset = bits.se();
  if (weight < -128 || weight > 127 || offset < -128 || offset > 127) {
    throw const FormatException('Invalid H.264 prediction weight');
  }
  return (weight: weight, offset: offset);
}

/// Header syntax shared by independently decodable and inter-coded slices.
final class SliceHeader {
  SliceHeader(Uint8List nal, Map<int, H264Pps> pictures)
    : bits = Rbsp.fromNal(nal) {
    final type = nal[0] & 31;
    idr = type == 5;
    reference = nal[0] & 0x60 != 0;
    if ((type != 1 && !idr) || (idr && !reference)) {
      throw const FormatException('Invalid H.264 coded slice');
    }
    firstMb = bits.ue();
    final kindValue = bits.ue(9) % 5;
    if (kindValue > 2)
      throw UnsupportedError('H.264 SP/SI slices are unavailable');
    kind = SliceKind.values[kindValue];
    if (idr && kind != SliceKind.intra) {
      throw const FormatException('H.264 IDR slice is not intra');
    }
    final picture = pictures[bits.ue(255)];
    if (picture == null)
      throw const FormatException('H.264 slice references a missing PPS');
    pps = picture;
    final sps = pps.sps;
    if (!sps.frameOnly || pps.sliceGroups != 1 || sps.separateColorPlane) {
      throw UnsupportedError(
        'Interlaced and slice-group H.264 pictures are unavailable',
      );
    }
    frameNum = bits.read(sps.frameNumBits);
    if (idr) idrId = bits.ue(65535);
    if (sps.pocType == 0) {
      pocLsb = bits.read(sps.pocLsbBits);
      if (pps.bottomFieldPocPresent) deltaBottom = bits.se();
    } else if (sps.pocType == 1 && !sps.deltaPocAlwaysZero) {
      delta0 = bits.se();
      if (pps.bottomFieldPocPresent) delta1 = bits.se();
    }
    if (pps.redundantPicCount && bits.ue(127) != 0) {
      throw UnsupportedError('Redundant H.264 slices are unavailable');
    }
    if (kind == SliceKind.b) directSpatial = bits.flag();
    if (kind != SliceKind.intra) {
      final override = bits.flag();
      activeL0 = override ? bits.ue(31) + 1 : pps.activeL0;
      if (kind == SliceKind.b)
        activeL1 = override ? bits.ue(31) + 1 : pps.activeL1;
      list0 = _modifications(activeL0);
      if (kind == SliceKind.b) list1 = _modifications(activeL1);
    }
    if ((kind == SliceKind.p && pps.weightedP) ||
        (kind == SliceKind.b && pps.weightedB == 1)) {
      weights = PredictionWeights.read(bits, sps, activeL0, activeL1);
    }
    if (reference) _referenceMarking();
    if (pps.cabac && kind != SliceKind.intra) cabacInit = bits.ue(2);
    qp = pps.initialQp + bits.se();
    if (qp < -6 * (sps.lumaDepth - 8) ||
        qp > 51 ||
        firstMb >= sps.mbWidth * sps.mbHeight) {
      throw const FormatException(
        'Invalid H.264 slice QP or macroblock address',
      );
    }
    if (pps.deblockingControl) {
      deblocking = bits.ue(2);
      if (deblocking != 1) {
        alphaOffset = 2 * bits.se();
        betaOffset = 2 * bits.se();
        if (alphaOffset.abs() > 12 || betaOffset.abs() > 12) {
          throw const FormatException('Invalid H.264 deblocking offset');
        }
      }
    }
    if (pps.cabac) bits.align(1);
  }

  final Rbsp bits;
  late final int firstMb, frameNum, qp;
  late final H264Pps pps;
  late final SliceKind kind;
  late final bool idr, reference;

  var idrId = 0, pocLsb = 0, deltaBottom = 0, delta0 = 0, delta1 = 0;
  var deblocking = 0, alphaOffset = 0, betaOffset = 0;
  var activeL0 = 0, activeL1 = 0, cabacInit = 0;
  var directSpatial = false, longTermIdr = false;
  var list0 = const <ReferenceModification>[],
      list1 = const <ReferenceModification>[];
  List<ReferenceMarking>? marking;
  PredictionWeights? weights;

  bool samePicture(SliceHeader other) =>
      pps == other.pps &&
      frameNum == other.frameNum &&
      idr == other.idr &&
      idrId == other.idrId &&
      pocLsb == other.pocLsb &&
      deltaBottom == other.deltaBottom &&
      delta0 == other.delta0 &&
      delta1 == other.delta1 &&
      reference == other.reference;

  List<ReferenceModification> _modifications(int active) {
    if (!bits.flag()) return const [];
    final result = <ReferenceModification>[];
    while (true) {
      final op = bits.ue(3);
      if (op == 3) return result;
      if (result.length >= active)
        throw const FormatException(
          'Too many H.264 reference list modifications',
        );
      final maximum = op == 2 ? 15 : (1 << pps.sps.frameNumBits) - 1;
      result.add((op: op, value: bits.ue(maximum)));
    }
  }

  void _referenceMarking() {
    if (idr) {
      bits.bit(); // no_output_of_prior_pics_flag
      longTermIdr = bits.flag();
      return;
    }
    if (!bits.flag()) return;
    final operations = marking = [];
    while (true) {
      final op = bits.ue(6);
      if (op == 0) return;
      if (operations.length >= 32)
        throw const FormatException('Too many H.264 reference markings');
      final maximum = (1 << pps.sps.frameNumBits) - 1;
      final first = switch (op) {
        1 || 3 => bits.ue(maximum),
        2 || 6 => bits.ue(15),
        4 => bits.ue(16),
        _ => 0,
      };
      operations.add((op: op, first: first, second: op == 3 ? bits.ue(15) : 0));
    }
  }
}
