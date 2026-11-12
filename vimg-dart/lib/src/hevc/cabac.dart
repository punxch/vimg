import 'dart:typed_data';

import '../cabac_engine.dart';
import '../rbsp.dart';
import 'contexts.dart';
import 'slice_header.dart';

/// HEVC CABAC initialization for the first substream or an independent tile.
/// Wavefront rows can instead start with models saved after the second CTU
/// of the preceding row.
final class HevcCabac extends CabacEngine {
  HevcCabac(Rbsp bits, HevcSliceParameters slice, {Uint8List? savedModels})
    : super(
        bits,
        savedModels == null
            ? _initialModels(slice)
            : Uint8List.fromList(savedModels),
      );

  int decode(HevcContext context, [int increment = 0]) {
    if (increment < 0 || increment >= context.length) {
      throw const FormatException('Invalid HEVC CABAC context increment');
    }
    return decision(context.offset + increment);
  }

  int bypassBits(int count) {
    var value = 0;
    for (var i = 0; i < count; i++) {
      value = (value << 1) | bypass();
    }
    return value;
  }

  int bypassGolomb(int order) {
    var base = 0;
    while (bypass() != 0) {
      base += 1 << order++;
      if (order > 22)
        throw const FormatException('Oversized HEVC CABAC escape');
    }
    return base + bypassBits(order);
  }
}

Uint8List _initialModels(HevcSliceParameters slice) {
  final type = switch (slice.kind) {
    HevcSliceKind.intra => 0,
    HevcSliceKind.p => slice.cabacInit ? 2 : 1,
    HevcSliceKind.b => slice.cabacInit ? 1 : 2,
  };
  final table = hevcContextInit[type];
  final qp = slice.qp.clamp(0, 51);
  final models = Uint8List(table.length);
  for (var i = 0; i < models.length; i++) {
    final value = table[i];
    models[i] = value < 0
        ? 126
        : cabacModel((value >> 4) * 5 - 45, ((value & 15) << 3) - 16, qp);
  }
  return models;
}
