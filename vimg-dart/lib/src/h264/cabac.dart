import 'dart:typed_data';

import '../cabac_engine.dart';
import '../rbsp.dart';
import 'cabac_tables.dart';

/// H.264 probability initialization and coefficient escape codes (§9.3).
final class Cabac extends CabacEngine {
  Cabac(Rbsp bits, int qp, {int? interInit, bool fullChroma = false})
    : super(bits, _models(qp, interInit, fullChroma));

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

Uint8List _models(int qp, int? interInit, bool fullChroma) {
  final table = interInit == null
      ? intraContextInit
      : interContextInit[interInit];
  final extra = fullChroma
      ? chroma444ContextInit[interInit == null ? 0 : interInit + 1]
      : const <int>[];
  final models = Uint8List((table.length + extra.length) ~/ 2);
  final initialQp = qp.clamp(0, 51);
  var model = 0;
  for (final init in [table, extra]) {
    for (var i = 0; i < init.length; i += 2) {
      models[model++] = cabacModel(init[i], init[i + 1], initialQp);
    }
  }
  return models;
}
