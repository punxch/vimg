import 'dart:typed_data';

import '../cabac_engine.dart';
import '../rbsp.dart';
import 'cabac_tables.dart';

/// H.264 probability initialization and coefficient escape codes (§9.3).
final class Cabac extends CabacEngine {
  Cabac(Rbsp bits, int qp, {int? interInit})
    : super(bits, _models(qp, interInit));

  int coefficientSuffix() {
    var prefix = 0;
    while (bypass() != 0) {
      if (++prefix > 16)
        throw const FormatException('Oversized H.264 coefficient');
    }
    var suffix = 0;
    for (var bit = 0; bit < prefix; bit++) {
      suffix = (suffix << 1) | bypass();
    }
    return (1 << prefix) - 1 + suffix;
  }
}

Uint8List _models(int qp, int? interInit) {
  final table = interInit == null
      ? intraContextInit
      : interContextInit[interInit];
  final models = Uint8List(table.length ~/ 2);
  final initialQp = qp.clamp(0, 51);
  for (var i = 0; i < models.length; i++) {
    models[i] = cabacModel(table[2 * i], table[2 * i + 1], initialQp);
  }
  return models;
}
