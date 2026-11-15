import 'b_motion.dart';
import 'motion.dart';
import 'reference.dart';
import 'slice_header.dart';

/// Inter prediction for progressive pictures (§8.4.2.2–8.4.2.3).
void predictInter(
  List<int> output,
  int plane,
  int mbX,
  int mbY,
  int owner,
  MotionField motion0,
  MotionField? motion1,
  ReferenceLists references,
  SliceHeader header,
  int poc,
) {
  final luma = plane == 0;
  final sps = header.pps.sps;
  final depth = luma ? sps.lumaDepth : sps.chromaDepth;
  final maximum = (1 << depth) - 1;
  final offsetShift = depth - 8;
  final fullSize = luma || sps.fullChroma;
  final blockWidth = fullSize ? 4 : 2;
  final blockHeight = fullSize ? 4 : sps.chromaHeight ~/ 4;
  final size = blockWidth * 4;
  final unit = fullSize ? 4 : 8;
  final weights = header.weights;
  final denominator = luma ? weights?.lumaShift : weights?.chromaShift;
  for (var py = 0; py < 4; py++) {
    for (var px = 0; px < 4; px++) {
      final x = mbX * 4 + px, y = mbY * 4 + py;
      final index0 = motion0.referenceAt(x, y, owner);
      final index1 = motion1?.referenceAt(x, y, owner) ?? -1;
      final first = index0 < 0
          ? null
          : _source(
              getReference(references.l0, index0),
              plane,
              x,
              y,
              motion0,
              header.bottomField,
            );
      final second = index1 < 0
          ? null
          : _source(
              getReference(references.l1, index1),
              plane,
              x,
              y,
              motion1!,
              header.bottomField,
            );
      if (first == null && second == null) {
        throw const FormatException('H.264 inter block has no reference');
      }
      final weight0 = index0 < 0 ? null : weights?.l0[index0][plane];
      final weight1 = index1 < 0 ? null : weights?.l1[index1][plane];
      final targetX = px * blockWidth, targetY = py * blockHeight;
      var implicit = 32;
      if (first != null &&
          second != null &&
          header.pps.weightedB == 2 &&
          first.ref.longIndex == null &&
          second.ref.longIndex == null &&
          first.ref.poc != second.ref.poc) {
        final scale = distanceScale(first.ref.poc, second.ref.poc, poc) >> 2;
        if (scale >= -64 && scale <= 128) implicit = scale;
      }
      for (var row = 0; row < blockHeight; row++) {
        for (var col = 0; col < blockWidth; col++) {
          final dx = col * unit, dy = row * unit;
          final int sample;
          if (first == null || second == null) {
            final raw = _interSample(
              first ?? second!,
              fullSize,
              dx,
              dy,
              maximum,
            );
            final weight = weight0 ?? weight1;
            sample = weight == null
                ? raw
                : _weighted(raw, weight, denominator!, offsetShift, maximum);
          } else {
            final a = _interSample(first, fullSize, dx, dy, maximum);
            final b = _interSample(second, fullSize, dx, dy, maximum);
            if (weight0 != null && weight1 != null) {
              final shift = denominator!;
              final offset = (weight0.offset + weight1.offset) << offsetShift;
              sample =
                  (((a * weight0.weight + b * weight1.weight + (1 << shift)) >>
                              (shift + 1)) +
                          ((offset + 1) >> 1))
                      .clamp(0, maximum);
            } else {
              sample = implicit == 32
                  ? _average(a, b)
                  : (((64 - implicit) * a + implicit * b + 32) >> 6).clamp(
                      0,
                      maximum,
                    );
            }
          }
          output[(targetY + row) * size + targetX + col] = sample;
        }
      }
    }
  }
}

typedef _Source = ({
  ReferencePicture ref,
  List<int> data,
  int stride,
  int height,
  int x,
  int y,
});

_Source _source(
  ReferencePicture ref,
  int plane,
  int x,
  int y,
  MotionField field,
  bool? bottomField,
) {
  final picture = ref.picture!;
  final data = switch (plane) {
    0 => picture.y,
    1 => picture.cb,
    _ => picture.cr,
  };
  final stride = plane == 0 ? picture.stride : picture.chromaStride;
  final vector = field.vectorAt(x, y);
  final chroma420 = plane != 0 && picture.sps.chromaFormat == 1;
  final correction = chroma420 && bottomField != picture.bottomField
      ? (bottomField == true ? 2 : -2)
      : 0;
  return (
    ref: ref,
    data: data,
    stride: stride,
    height: data.length ~/ stride,
    x: 16 * x + vector.x,
    y:
        (16 * y + vector.y + correction) <<
        (plane != 0 && picture.sps.chromaFormat == 2 ? 1 : 0),
  );
}

int _interSample(_Source source, bool fullSize, int dx, int dy, int maximum) =>
    fullSize
    ? _luma(
        source.data,
        source.stride,
        source.height,
        source.x + dx,
        source.y + dy,
        maximum,
      )
    : _chroma(
        source.data,
        source.stride,
        source.height,
        source.x + dx,
        source.y + dy,
      );

int _weighted(
  int sample,
  PredictionWeight weight,
  int shift,
  int offsetShift,
  int maximum,
) {
  final round = shift == 0 ? 0 : 1 << (shift - 1);
  return (((sample * weight.weight + round) >> shift) +
          (weight.offset << offsetShift))
      .clamp(0, maximum);
}

int _sample(List<int> data, int stride, int height, int x, int y) =>
    data[y.clamp(0, height - 1) * stride + x.clamp(0, stride - 1)];

int _chroma(List<int> data, int stride, int height, int x8, int y8) {
  final x = x8 >> 3, y = y8 >> 3;
  final dx = x8 & 7, dy = y8 & 7;
  final a = _sample(data, stride, height, x, y);
  if (dx == 0 && dy == 0) return a;
  final b = _sample(data, stride, height, x + 1, y);
  final c = _sample(data, stride, height, x, y + 1);
  final d = _sample(data, stride, height, x + 1, y + 1);
  return ((8 - dx) * ((8 - dy) * a + dy * c) +
          dx * ((8 - dy) * b + dy * d) +
          32) >>
      6;
}

int _luma(List<int> data, int stride, int height, int x4, int y4, int maximum) {
  final x = x4 >> 2, y = y4 >> 2;
  final dx = x4 & 3, dy = y4 & 3;
  if (dx == 0 && dy == 0) return _sample(data, stride, height, x, y);
  if (dy == 0) {
    final half = _halfX(data, stride, height, x, y, maximum);
    return dx == 2
        ? half
        : _average(half, _sample(data, stride, height, x + (dx >> 1), y));
  }
  if (dx == 0) {
    final half = _halfY(data, stride, height, x, y, maximum);
    return dy == 2
        ? half
        : _average(half, _sample(data, stride, height, x, y + (dy >> 1)));
  }
  if (dx == 2 || dy == 2) {
    final half = _diagonal(data, stride, height, x, y, maximum);
    if (dx == 2 && dy == 2) return half;
    return dx == 2
        ? _average(
            half,
            _halfX(data, stride, height, x, y + (dy >> 1), maximum),
          )
        : _average(
            half,
            _halfY(data, stride, height, x + (dx >> 1), y, maximum),
          );
  }
  return _average(
    _halfX(data, stride, height, x, y + (dy >> 1), maximum),
    _halfY(data, stride, height, x + (dx >> 1), y, maximum),
  );
}

int _average(int a, int b) => (a + b + 1) >> 1;

int _six(int a, int b, int c, int d, int e, int f) =>
    a - 5 * (b + e) + 20 * (c + d) + f;

int _horizontal(List<int> data, int stride, int height, int x, int y) {
  final row = y.clamp(0, height - 1) * stride;
  if (x >= 2 && x + 3 < stride) {
    final p = row + x;
    return _six(
      data[p - 2],
      data[p - 1],
      data[p],
      data[p + 1],
      data[p + 2],
      data[p + 3],
    );
  }
  int at(int offset) => data[row + (x + offset).clamp(0, stride - 1)];
  return _six(at(-2), at(-1), at(0), at(1), at(2), at(3));
}

int _halfX(List<int> data, int stride, int height, int x, int y, int maximum) =>
    ((_horizontal(data, stride, height, x, y) + 16) >> 5).clamp(0, maximum);

int _halfY(List<int> data, int stride, int height, int x, int y, int maximum) {
  final column = x.clamp(0, stride - 1);
  if (y >= 2 && y + 3 < height) {
    final p = y * stride + column;
    return ((_six(
                  data[p - 2 * stride],
                  data[p - stride],
                  data[p],
                  data[p + stride],
                  data[p + 2 * stride],
                  data[p + 3 * stride],
                ) +
                16) >>
            5)
        .clamp(0, maximum);
  }
  int at(int offset) =>
      data[(y + offset).clamp(0, height - 1) * stride + column];
  return ((_six(at(-2), at(-1), at(0), at(1), at(2), at(3)) + 16) >> 5).clamp(
    0,
    maximum,
  );
}

int _diagonal(
  List<int> data,
  int stride,
  int height,
  int x,
  int y,
  int maximum,
) {
  int at(int offset) => _horizontal(data, stride, height, x, y + offset);
  return ((_six(at(-2), at(-1), at(0), at(1), at(2), at(3)) + 512) >> 10).clamp(
    0,
    maximum,
  );
}
