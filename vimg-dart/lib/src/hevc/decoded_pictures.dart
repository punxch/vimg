import 'picture.dart';
import 'slice_header.dart';

typedef HevcReferencePicture = ({HevcPicture picture, int poc, bool longTerm});
typedef HevcReferenceLists = ({
  List<HevcReferencePicture> l0,
  List<HevcReferencePicture> l1,
});

/// H.265 §8.3.2 and §8.3.4. Retain the following-picture references as
/// well as those used by the current picture.
final class HevcDecodedPictures {
  final _pictures = <int, HevcReferencePicture>{};

  HevcReferenceLists lists(HevcSliceHeader slice, int poc) {
    final parameters = slice.parameters;
    final before = <HevcReferencePicture>[];
    final after = <HevcReferencePicture>[];
    final long = <HevcReferencePicture>[];
    for (final reference in parameters.shortReferences) {
      if (!reference.used) continue;
      final refPoc = poc + reference.deltaPoc;
      final picture = _require(slice, _pictures[refPoc], refPoc);
      (reference.deltaPoc < 0 ? before : after).add((
        picture: picture.picture,
        poc: refPoc,
        longTerm: false,
      ));
    }
    for (final reference in parameters.longReferences) {
      if (!reference.used) continue;
      final picture = _require(
        slice,
        _long(slice, poc, reference),
        reference.pocLsb,
      );
      long.add((picture: picture.picture, poc: picture.poc, longTerm: true));
    }

    List<HevcReferencePicture> select(
      List<HevcReferencePicture> entries,
      int count,
      List<int> modification,
    ) => List.generate(count, (i) {
      final index = modification.isEmpty ? i % entries.length : modification[i];
      return entries[index];
    }, growable: false);

    return (
      l0: select(
        [...before, ...after, ...long],
        parameters.activeL0,
        parameters.list0,
      ),
      l1: select(
        [...after, ...before, ...long],
        parameters.activeL1,
        parameters.list1,
      ),
    );
  }

  void update(HevcSliceHeader slice, int poc, HevcPicture picture) {
    final keep = <int, HevcReferencePicture>{};
    for (final reference in slice.parameters.shortReferences) {
      final refPoc = poc + reference.deltaPoc;
      final previous = _pictures[refPoc];
      if (previous != null)
        keep[refPoc] = (
          picture: previous.picture,
          poc: refPoc,
          longTerm: false,
        );
    }
    for (final reference in slice.parameters.longReferences) {
      final previous = _long(slice, poc, reference);
      if (previous != null)
        keep[previous.poc] = (
          picture: previous.picture,
          poc: previous.poc,
          longTerm: true,
        );
    }
    if (slice.nal.randomAccess || slice.nal.type.isOdd)
      keep[poc] = (picture: picture, poc: poc, longTerm: false);
    _pictures
      ..clear()
      ..addAll(keep);
  }

  HevcReferencePicture? _long(
    HevcSliceHeader slice,
    int poc,
    HevcSliceLongReference reference,
  ) {
    final max = 1 << slice.sps.pocBits;
    final mask = max - 1;
    if (reference.msbCycle case final cycle?) {
      return _pictures[(poc & ~mask) + reference.pocLsb - cycle * max];
    }
    HevcReferencePicture? candidate;
    for (final picture in _pictures.values) {
      if ((picture.poc & mask) != reference.pocLsb) continue;
      if (picture.longTerm) return picture;
      candidate = picture;
    }
    return candidate;
  }

  static HevcReferencePicture _require(
    HevcSliceHeader slice,
    HevcReferencePicture? picture,
    int poc,
  ) {
    if (picture == null)
      throw FormatException('Missing HEVC reference picture POC $poc');
    final current = slice.sps, previous = picture.picture.sps;
    if (current.codedWidth != previous.codedWidth ||
        current.codedHeight != previous.codedHeight ||
        current.chromaArrayType != previous.chromaArrayType ||
        current.separateColourPlane != previous.separateColourPlane ||
        current.lumaDepth != previous.lumaDepth ||
        (!current.separateColourPlane &&
            current.chromaDepth != previous.chromaDepth))
      throw const FormatException('Incompatible HEVC reference picture format');
    return picture;
  }
}
