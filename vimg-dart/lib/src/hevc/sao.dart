import 'dart:math' as math;

import 'cabac.dart';
import 'contexts.dart';
import 'slice_header.dart';

typedef HevcSaoComponent = ({int type, int position, List<int> offsets});
typedef HevcSao = List<HevcSaoComponent>;

const _off = (type: 0, position: 0, offsets: <int>[]);
const hevcSaoOff = [_off, _off, _off];

HevcSao readHevcSao(
  HevcCabac cabac,
  HevcSliceHeader slice,
  HevcSao? left,
  HevcSao? above,
) {
  final parameters = slice.parameters;
  if (!parameters.saoLuma && !parameters.saoChroma) return hevcSaoOff;
  if (left != null && cabac.decode(HevcContext.saoMergeFlag) != 0) return left;
  if (above != null && cabac.decode(HevcContext.saoMergeFlag) != 0)
    return above;
  final result = <HevcSaoComponent>[];
  for (var c = 0; c < 3; c++) {
    if (!(c == 0 ? parameters.saoLuma : parameters.saoChroma)) {
      result.add(_off);
      continue;
    }
    final type = c == 2
        ? result[1].type
        : cabac.decode(HevcContext.saoTypeIdx) == 0
        ? 0
        : 1 + cabac.bypass();
    if (type == 0) {
      result.add(_off);
      continue;
    }
    final depth = c == 0 ? slice.sps.lumaDepth : slice.sps.chromaDepth;
    final maximum = (1 << (math.min(depth, 10) - 5)) - 1;
    final values = List.generate(4, (_) {
      var magnitude = 0;
      while (magnitude < maximum && cabac.bypass() != 0) magnitude++;
      return magnitude;
    });
    final int position;
    if (type == 1) {
      for (var i = 0; i < 4; i++) {
        if (values[i] != 0 && cabac.bypass() != 0) values[i] = -values[i];
      }
      position = cabac.bypassBits(5);
    } else {
      values[2] = -values[2];
      values[3] = -values[3];
      position = c == 2 ? result[1].position : cabac.bypassBits(2);
    }
    final range = slice.pps.rangeExtension;
    final shift = (c == 0 ? range?.saoLumaScale : range?.saoChromaScale) ?? 0;
    for (var i = 0; i < values.length; i++) {
      values[i] <<= shift;
    }
    result.add((type: type, position: position, offsets: values));
  }
  return result;
}
