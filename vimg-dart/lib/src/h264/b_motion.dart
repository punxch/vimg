import 'motion.dart';
import 'reference.dart';
import 'slice_header.dart';

/// Direct B prediction derives motion from adjacent partitions and the
/// co-located list-1 picture. It consumes no reference or MVD bins.
final class BDirect {
  const BDirect(
    this.header,
    this.poc,
    this.refs,
    this.l0,
    this.l1, {
    this.mbaffBottomField,
  });

  final SliceHeader header;
  final int poc;
  final ReferenceLists refs;
  final MotionField l0, l1;
  final bool? mbaffBottomField;

  void derive(MotionPartition whole, List<MotionPartition> parts, int owner) {
    final col = getReference(refs.l1, 0);
    final parity = mbaffBottomField ?? header.bottomField;
    final pair = col.fields;
    final chooseBottom =
        parity ??
        (pair == null ||
            (pair.top.poc - poc).abs() >= (pair.bottom.poc - poc).abs());
    final colocatedPicture = pair == null
        ? col
        : (chooseBottom ? pair.bottom : pair.top);
    final reference = colocatedPicture.picture!;
    final mbRow = whole.y ~/ 4;
    final pairRow = header.field ? mbRow : mbRow ~/ 2;
    final pairs = reference.mbaffFieldPairs;
    final colocatedField =
        reference.bottomField != null ||
        pairs?[pairRow * reference.sps.mbWidth + whole.x ~/ 4] == 1;
    final changesStructure = colocatedField != (parity != null);

    // Table 8-8 locates co-located motion in the reference's frame or
    // field macroblock geometry, using 4×4 block rows here.
    int colocatedRow(int y) {
      final local = y % 4;
      if (!colocatedField) return parity == null ? y : 8 * pairRow + 2 * local;
      if (pairs == null) {
        if (header.field) return y;
        return 4 * pairRow +
            (parity != null ? local : 2 * (mbRow & 1) + local ~/ 2);
      }
      final fieldRow =
          2 * pairRow + (colocatedPicture.bottomField == true ? 1 : 0);
      return 4 * fieldRow +
          (parity != null ? local : 2 * (mbRow & 1) + local ~/ 2);
    }

    final spatial = header.directSpatial;
    var r0 = spatial ? l0.spatialReference(whole, owner) : 0;
    var r1 = spatial ? l1.spatialReference(whole, owner) : 0;
    final directZero = spatial && r0 < 0 && r1 < 0;
    if (directZero) r0 = r1 = 0;
    final m0 = spatial && !directZero && r0 >= 0
        ? l0.predict(whole, owner, r0)
        : zeroMotion;
    final m1 = spatial && !directZero && r1 >= 0
        ? l1.predict(whole, owner, r1)
        : zeroMotion;
    final step = header.pps.sps.direct8x8 ? 2 : 1;
    for (final part in parts) {
      l0.markDirect(part);
      for (var y = part.y; y < part.y + part.height; y += step) {
        for (var x = part.x; x < part.x + part.width; x += step) {
          final cell = (x: x, y: y, width: step, height: step);
          final colX = step == 2 ? whole.x + ((x - whole.x) ~/ 2) * 3 : x;
          final colY = step == 2 ? whole.y + ((y - whole.y) ~/ 2) * 3 : y;
          final colocated = _motionAt(
            colocatedPicture,
            colX,
            colocatedRow(colY),
          );
          if (spatial) {
            final zero =
                col.longIndex == null &&
                colocated?.index == 0 &&
                colocated!.vector.x.abs() <= 1 &&
                colocated.vector.y.abs() <= 1;
            _write(
              l0,
              refs.l0,
              cell,
              owner,
              r0,
              zero && r0 == 0 ? zeroMotion : m0,
            );
            _write(
              l1,
              refs.l1,
              cell,
              owner,
              r1,
              zero && r1 == 0 ? zeroMotion : m1,
            );
          } else if (colocated == null) {
            _write(l0, refs.l0, cell, owner, 0, zeroMotion);
            _write(l1, refs.l1, cell, owner, 0, zeroMotion);
          } else {
            final identity = changesStructure
                ? referenceIdentityWithParity(colocated.identity, parity)
                : colocated.identity;
            final index = refs.l0.indexWhere(
              (ref) => ref?.identity == identity,
            );
            final ref = getReference(refs.l0, index);
            final raw = colocated.vector;
            final mv = (
              x: raw.x,
              y: !changesStructure
                  ? raw.y
                  : (parity != null ? raw.y ~/ 2 : raw.y * 2),
            );
            final factor = ref.longIndex != null
                ? 256
                : distanceScale(ref.poc, col.poc, poc);
            final forward = (
              x: signedMotion((factor * mv.x + 128) >> 8),
              y: signedMotion((factor * mv.y + 128) >> 8),
            );
            final backward = (
              x: signedMotion(forward.x - mv.x),
              y: signedMotion(forward.y - mv.y),
            );
            _write(l0, refs.l0, cell, owner, index, forward);
            _write(l1, refs.l1, cell, owner, 0, backward);
          }
        }
      }
    }
  }
}

({int index, int identity, MotionVector vector})? _motionAt(
  ReferencePicture ref,
  int x,
  int y,
) {
  final picture = ref.picture!;
  var field = picture.motionL0;
  var index = field?.storedReferenceAt(x, y) ?? -1;
  if (index < 0) {
    field = picture.motionL1;
    index = field?.storedReferenceAt(x, y) ?? -1;
  }
  if (index < 0) return null;
  return (
    index: index,
    identity: field!.identityAt(x, y),
    vector: field.vectorAt(x, y),
  );
}

void _write(
  MotionField field,
  List<ReferencePicture?> refs,
  MotionPartition part,
  int owner,
  int index,
  MotionVector vector,
) {
  if (index < 0) {
    field.setUnused(part, owner);
    return;
  }
  field.setReference(part, owner, index, getReference(refs, index).identity);
  field.setVector(part, vector, zeroMotion);
}

int distanceScale(int referencePoc, int colocatedPoc, int currentPoc) {
  final td = (colocatedPoc - referencePoc).clamp(-128, 127);
  if (td == 0) return 256;
  final tb = (currentPoc - referencePoc).clamp(-128, 127);
  final tx = (16384 + (td ~/ 2).abs()) ~/ td;
  return ((tb * tx + 32) >> 6).clamp(-1024, 1023);
}
