import 'dart:math' as math;
import 'dart:typed_data';

import 'access_unit.dart';
import 'reference.dart';
import 'slice_header.dart';

typedef AvcOrder = ({
  int type,
  int poc,
  bool reset,
  bool randomAccess,
  H264FieldKey? field,
});

/// Advance the decoder's picture-order and reference-marking state using
/// slice headers alone. A sample may carry both fields of a picture.
final class AvcPictureOrder {
  AvcPictureOrder(this.configuration);

  final AvcConfiguration configuration;
  final _references = ReferenceState();
  var _started = false;

  AvcOrder? observe(
    Uint8List sample, {
    void Function((int, int), Uint8List)? onParameterSet,
  }) {
    SliceHeader? previous;
    int? poc, type;
    H264FieldKey? field;
    var reset = false, randomAccess = false;
    for (final nal in configuration.nals(sample)) {
      final nalType = nal[0] & 31;
      if (nalType == 7 || nalType == 8) {
        final key = configuration.store(nal)!;
        onParameterSet?.call(key, nal);
      } else if (nalType == 5 || nalType == 1 && _started) {
        final slice = SliceHeader(nal, configuration.pictures);
        if (slice.colorPlane != 0 || previous?.samePicture(slice) == true) {
          continue;
        }
        if (previous != null &&
            (field == null || !slice.complements(previous))) {
          throw const FormatException('Unrelated H.264 pictures in one sample');
        }
        _started = true;
        final pending = _references.begin(slice);
        _references.commit(pending, null);
        final clearsNumber =
            slice.marking?.any((entry) => entry.op == 5) == true;
        randomAccess |= pending.idrStart;
        reset |= pending.idrStart || clearsNumber;
        final fieldOrder = pending.pocFor(slice.bottomField);
        poc = clearsNumber ? 0 : math.min(poc ?? fieldOrder, fieldOrder);
        type ??= nalType;
        field = previous == null && slice.bottomField != null
            ? (
                sequence: slice.pps.sps.id,
                frameNum: slice.frameNum,
                bottom: slice.bottomField!,
                reference: slice.reference,
              )
            : null;
        previous = slice;
      }
    }
    return poc == null
        ? null
        : (
            type: type!,
            poc: poc,
            reset: reset,
            randomAccess: randomAccess,
            field: field,
          );
  }
}
