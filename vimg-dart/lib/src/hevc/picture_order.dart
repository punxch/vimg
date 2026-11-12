import 'slice_header.dart';

typedef HevcOrder = ({int poc, bool output, bool discardRasl});

/// H.265 §8.3.1 picture-order state for a decode-order stream started at an
/// IRAP picture. A fresh instance also models a seek directly to a CRA.
final class HevcPictureOrder {
  int? _previousTid0;
  var _suppressRasl = false;

  HevcOrder observe(HevcSliceHeader first) {
    if (!first.first)
      throw const FormatException('HEVC picture has no first slice');
    final nal = first.nal;
    final previous = _previousTid0;
    if (previous == null && !nal.randomAccess) {
      throw const FormatException(
        'HEVC decoding must start at a random-access picture',
      );
    }
    final reset = nal.randomAccess && (previous == null || nal.type < 21);
    if (nal.randomAccess) _suppressRasl = reset;
    final lsb = first.parameters.pocLsb;
    final maximum = 1 << first.sps.pocBits;
    var msb = 0;
    if (!reset) {
      final priorLsb = previous! & (maximum - 1);
      msb = previous - priorLsb;
      if (lsb < priorLsb && priorLsb - lsb >= maximum ~/ 2) {
        msb += maximum;
      } else if (lsb > priorLsb && lsb - priorLsb > maximum ~/ 2) {
        msb -= maximum;
      }
    }
    final poc = nal.idr ? 0 : msb + lsb;
    final sublayerNonReference = nal.type <= 9 && nal.type.isEven;
    if (nal.temporalId == 0 &&
        !nal.rasl &&
        !nal.radl &&
        !sublayerNonReference) {
      _previousTid0 = poc;
    }
    final discard = nal.rasl && _suppressRasl;
    return (
      poc: poc,
      output: first.parameters.output && !discard,
      discardRasl: discard,
    );
  }
}
