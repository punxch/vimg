import 'dart:typed_data';

import 'package:vimg_dart/src/av1/bitstream.dart';
import 'package:vimg_dart/src/av1/frame_parameters.dart';
import 'package:vimg_dart/src/av1/picture_decoder.dart';
import 'package:vimg_dart/src/av1/sequence_header.dart';
import 'package:vimg_dart/src/avif_animation.dart';

import 'fixtures.dart';

void main() {
  _checkAnimation();

  // Odd dimensions exercise partial blocks and the final chroma luma sample.
  // Expected checksums come from the scalar dav1d grain synthesis routine.
  const cases = [
    _GrainCase(
      depth: 12,
      sx: 1,
      lag: 3,
      luma: false,
      cb: true,
      expected: [0x88d4e5da, 0xb76f6f66, 0x29fbacec],
    ),
    _GrainCase(
      depth: 10,
      sx: 1,
      sy: 1,
      lag: 2,
      chromaFromLuma: true,
      expected: [0x8691a618, 0xc5ff943d, 0x3f9fbdb6],
    ),
    _GrainCase(
      depth: 8,
      matrix: 0,
      lag: 1,
      grainShift: 2,
      cb: true,
      cr: true,
      expected: [0x5bf22bd5, 0x62ddc4af, 0x57824096],
    ),
    _GrainCase(
      depth: 8,
      monochrome: true,
      overlap: false,
      restricted: false,
      expected: [0x6de37af5],
    ),
    _GrainCase(
      depth: 10,
      sx: 1,
      sy: 1,
      luma: false,
      chromaFromLuma: true,
      expected: [0xde4f89da, 0x8b498703, 0x346e11b1],
    ),
  ];
  for (final (index, test) in cases.indexed) {
    _checkSynthetic(index, test);
  }
}

void _checkAnimation() {
  final movie = AvifAnimation.open('test/fixtures/av1-svt-tiled.avif');
  try {
    final decoder = Av1StreamDecoder();
    final references = List.filled(3, 0);
    final displays = List.filled(3, 0);
    var frames = 0, reused = 0;
    for (final sample in movie.codedFrames()) {
      final frame = sample.frame;
      final reference = decoder.decode(frame);
      if (!sample.present) continue;
      final parameters = frame.header.parameters.filmGrain;
      final display = applyAv1FilmGrain(reference, parameters);
      if (frames == 0) {
        _checkReusedParameters(frame.sequence, parameters!);
        final preview = decodeAv1IntraImage(frame);
        final expected = display.rgb().getBytes();
        final streamOutput = decoder.display(frame, reference).getBytes();
        check(
          preview.getBytes().indexed.every(
            (entry) =>
                entry.$2 == expected[entry.$1] &&
                streamOutput[entry.$1] == expected[entry.$1],
          ),
          'AV1 grain in the keyframe preview and stream output',
        );
      }
      frames++;
      if (frame.syntax.existingSlot != null) reused++;
      for (final (p, plane) in display.planes.indexed) {
        displays[p] = _checksum(plane, displays[p]);
        references[p] = _checksum(reference.planes[p], references[p]);
      }
    }
    check(frames == 17 && reused == 8, 'AV1 film grain display order');
    _checkHashes(displays, [0xb2df12b3, 0x2e91f5ed, 0x04a8b688], 'display');
    _checkHashes(references, [0x85d9d915, 0x19261105, 0x68456508], 'reference');
    check(movie.decodeFrames().length == frames, 'AVIF grain animation output');
  } finally {
    movie.close();
  }
}

void _checkReusedParameters(Av1SequenceHeader sequence, Av1FilmGrain original) {
  const seed = 53916, reference = 3;
  Av1Bits syntax() => Av1Bits(
    Uint8List.fromList(uint((1 << 23) | (seed << 7) | (reference << 3), 3)),
  );

  final inherited = readAv1FilmGrain(
    syntax(),
    sequence,
    visible: true,
    inter: true,
    fromReference: (slot) {
      check(slot == reference, 'AV1 grain reference slot');
      return original;
    },
  );
  check(
    inherited!.seed == seed &&
        identical(inherited.luma, original.luma) &&
        inherited.cb == original.cb &&
        inherited.cr == original.cr,
    'AV1 inherited grain parameters use the current seed',
  );
  check(
    readAv1FilmGrain(
          syntax(),
          sequence,
          visible: true,
          inter: true,
          fromReference: (_) => null,
        ) ==
        null,
    'AV1 reference with reset grain parameters',
  );
}

final class _GrainCase {
  const _GrainCase({
    required this.depth,
    required this.expected,
    this.sx = 0,
    this.sy = 0,
    this.lag = 0,
    this.grainShift = 0,
    this.matrix = 1,
    this.monochrome = false,
    this.luma = true,
    this.chromaFromLuma = false,
    this.cb = false,
    this.cr = false,
    this.overlap = true,
    this.restricted = true,
  });

  final int depth, sx, sy, lag, grainShift, matrix;
  final bool monochrome, luma, chromaFromLuma, cb, cr, overlap, restricted;
  final List<int> expected;
}

void _checkSynthetic(int index, _GrainCase test) {
  const width = 71, height = 69, stride = 96;
  final color = Av1ColorConfig(
    depth: test.depth,
    monochrome: test.monochrome,
    primaries: 1,
    transfer: test.matrix == 0 ? 13 : 1,
    matrix: test.matrix,
    fullRange: true,
    subsamplingX: test.sx,
    subsamplingY: test.sy,
    chromaPosition: 0,
    separateUvDelta: false,
  );
  final max = (1 << test.depth) - 1;
  final planes = [
    Av1Plane(width, height, stride, height),
    if (!test.monochrome)
      for (var p = 1; p < 3; p++)
        Av1Plane(
          (width + test.sx) >> test.sx,
          (height + test.sy) >> test.sy,
          stride,
          height,
        ),
  ];
  for (final (p, plane) in planes.indexed) {
    for (var y = 0; y < plane.height; y++) {
      for (var x = 0; x < plane.width; x++) {
        plane.samples[y * stride + x] =
            ((x * 181 + y * 131 + x * y * 3 + p * 239) ^
                ((x * 11 + y * 7) * (p + 1))) &
            max;
      }
    }
  }

  final clean = [for (final plane in planes) _checksum(plane)];
  final count = 2 * test.lag * (test.lag + 1);
  List<int> ar(int size, int p) => [
    for (var i = 0; i < size; i++) (i * 13 + p * 7) % 21 - 10,
  ];
  List<Av1GrainPoint> points(int p) => [
    (value: 7, scaling: 120 - 10 * p),
    (value: 63, scaling: 20 + 30 * p),
    (value: 148, scaling: 200 - 10 * p),
    (value: 248, scaling: 80 + 8 * p),
  ];
  Av1GrainChroma chroma(int p, bool active) => (
    points: active ? points(p) : const [],
    coefficients: active || test.chromaFromLuma
        ? ar(count + (test.luma ? 1 : 0), p)
        : const [],
    multiplier: p == 1 ? 72 : -48,
    lumaMultiplier: p == 1 ? 55 : 90,
    offset: p == 1 ? -40 : 64,
  );

  final result = applyAv1FilmGrain(Av1Picture(color, planes), (
    seed: 31415 + index * 137,
    luma: test.luma ? points(0) : const [],
    lumaCoefficients: test.luma ? ar(count, 0) : const [],
    chromaFromLuma: test.chromaFromLuma,
    cb: chroma(1, test.cb),
    cr: chroma(2, test.cr),
    scalingShift: 9,
    lag: test.lag,
    coefficientShift: 7,
    grainShift: test.grainShift,
    overlap: test.overlap,
    restrictedRange: test.restricted,
  ));
  _checkHashes(
    [for (final plane in result.planes) _checksum(plane)],
    test.expected,
    'synthetic case $index',
  );
  _checkHashes(
    [for (final plane in planes) _checksum(plane)],
    clean,
    'unchanged source for case $index',
  );
}

int _checksum(Av1Plane plane, [int hash = 0]) {
  for (var y = 0; y < plane.height; y++) {
    for (var x = 0; x < plane.width; x++) {
      hash =
          ((hash * 16777619) ^ plane.samples[y * plane.stride + x]) &
          0xffffffff;
    }
  }
  return hash;
}

void _checkHashes(List<int> actual, List<int> expected, String label) {
  check(actual.length == expected.length, 'AV1 grain $label plane count');
  for (final (p, hash) in actual.indexed) {
    check(
      hash == expected[p],
      'AV1 grain $label plane $p checksum ${hash.toRadixString(16)}',
    );
  }
}
