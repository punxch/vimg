import '../rbsp.dart';

typedef HevcShortReference = ({int deltaPoc, bool used});
typedef HevcLongReference = ({int pocLsb, bool used});

/// Short-term reference picture set in negative-then-positive POC order.
List<HevcShortReference> readShortReferences(
  Rbsp bits,
  List<List<HevcShortReference>> preceding, {
  bool inSlice = false,
}) {
  if (preceding.isNotEmpty && bits.flag()) {
    final index =
        preceding.length - 1 - (inSlice ? bits.ue(preceding.length - 1) : 0);
    final sign = bits.flag() ? -1 : 1;
    final delta = sign * (bits.ue(32767) + 1);
    final references = <HevcShortReference>[];
    for (final original in [
      ...preceding[index].map((ref) => ref.deltaPoc),
      0,
    ]) {
      final used = bits.flag();
      final include = used || bits.flag();
      final shifted = original + delta;
      if (include && shifted != 0)
        references.add((deltaPoc: shifted, used: used));
    }
    if (references.length > 16)
      throw const FormatException('Oversized HEVC reference set');
    references.sort((a, b) {
      if (a.deltaPoc.isNegative != b.deltaPoc.isNegative)
        return a.deltaPoc.isNegative ? -1 : 1;
      return a.deltaPoc.abs().compareTo(b.deltaPoc.abs());
    });
    return references;
  }

  final negatives = bits.ue(16);
  final positives = bits.ue(16 - negatives);
  final references = <HevcShortReference>[];
  var delta = 0;
  for (var i = 0; i < negatives; i++) {
    delta -= bits.ue(32767) + 1;
    references.add((deltaPoc: delta, used: bits.flag()));
  }
  delta = 0;
  for (var i = 0; i < positives; i++) {
    delta += bits.ue(32767) + 1;
    references.add((deltaPoc: delta, used: bits.flag()));
  }
  return references;
}
