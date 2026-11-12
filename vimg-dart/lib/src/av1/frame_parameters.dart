import 'bitstream.dart';
import 'sequence_header.dart';

typedef Av1Quantization = ({
  int base,
  int yDc,
  int uDc,
  int uAc,
  int vDc,
  int vAc,
  (int, int, int)? matrix,
});
typedef Av1Segmentation = ({
  bool enabled,
  bool updateMap,
  bool temporal,
  bool updateData,
  List<List<int?>> features,
});
typedef Av1DeltaFilter = ({int shift, bool multi});
typedef Av1LoopFilter = ({
  List<int> levels,
  int sharpness,
  bool enabled,
  List<int> references,
  List<int> modes,
});
typedef Av1Cdef = ({
  int damping,
  List<({int primary, int secondary})> y,
  List<({int primary, int secondary})> uv,
});
typedef Av1Restoration = ({
  List<Av1RestorationType> types,
  int lumaUnit,
  int chromaUnit,
});

enum Av1RestorationType { none, switchable, wiener, sgrproj }

enum Av1TransformMode { only4x4, largest, select }

enum Av1GlobalMotionType { identity, translation, rotZoom, affine }

typedef Av1GlobalMotion = ({Av1GlobalMotionType type, List<int> matrix});

const _identity = (
  type: Av1GlobalMotionType.identity,
  matrix: [0, 0, 65536, 0, 0, 65536],
);
const _inactiveSegment = <int?>[null, null, null, null, null, null, null, null];
const _inactiveSegments = [
  _inactiveSegment,
  _inactiveSegment,
  _inactiveSegment,
  _inactiveSegment,
  _inactiveSegment,
  _inactiveSegment,
  _inactiveSegment,
  _inactiveSegment,
];

Av1Quantization readAv1Quantization(Av1Bits bits, Av1ColorConfig color) {
  int delta() => bits.flag() ? bits.signed(7) : 0;
  final base = bits.read(8), y = delta();
  final separate = color.separateUvDelta && bits.flag();
  final udc = color.monochrome ? 0 : delta();
  final uac = color.monochrome ? 0 : delta();
  final vdc = separate ? delta() : udc, vac = separate ? delta() : uac;
  (int, int, int)? matrix;
  if (bits.flag()) {
    final y = bits.read(4), u = bits.read(4);
    matrix = (y, u, color.separateUvDelta ? bits.read(4) : u);
  }
  return (
    base: base,
    yDc: y,
    uDc: udc,
    uAc: uac,
    vDc: vdc,
    vAc: vac,
    matrix: matrix,
  );
}

Av1Segmentation readAv1Segmentation(Av1Bits bits, Av1Segmentation? previous) {
  if (!bits.flag()) {
    return (
      enabled: false,
      updateMap: false,
      temporal: false,
      updateData: false,
      features: _inactiveSegments,
    );
  }
  final updateMap = previous == null || bits.flag();
  final temporal = previous != null && updateMap && bits.flag();
  final updateData = previous == null || bits.flag();
  int? feature(int index) {
    if (!bits.flag()) return null;
    if (index == 0) return bits.signed(9).clamp(-255, 255);
    if (index < 5) return bits.signed(7).clamp(-63, 63);
    return index == 5 ? bits.read(3) : 0;
  }

  return (
    enabled: true,
    updateMap: updateMap,
    temporal: temporal,
    updateData: updateData,
    features: updateData
        ? List.unmodifiable(
            List.generate(
              8,
              (_) => List<int?>.unmodifiable(List.generate(8, feature)),
            ),
          )
        : previous.features,
  );
}

Av1LoopFilter readAv1LoopFilter(
  Av1Bits bits, {
  required bool filter,
  required bool chroma,
  required Av1LoopFilter? previous,
}) {
  const defaultRefs = [1, 0, 0, 0, -1, 0, -1, -1], defaultModes = [0, 0];
  if (!filter) {
    return (
      levels: const [0, 0, 0, 0],
      sharpness: 0,
      enabled: false,
      references: defaultRefs,
      modes: defaultModes,
    );
  }
  final vertical = bits.read(6), horizontal = bits.read(6);
  final hasChroma = chroma && (vertical != 0 || horizontal != 0);
  final levels = [
    vertical,
    horizontal,
    hasChroma ? bits.read(6) : 0,
    hasChroma ? bits.read(6) : 0,
  ];
  final sharpness = bits.read(3);
  final enabled = bits.flag();
  final update = enabled && bits.flag();
  List<int> deltas(List<int> prior) => !update
      ? prior
      : List.unmodifiable([
          for (final value in prior) bits.flag() ? bits.signed(7) : value,
        ]);
  return (
    levels: List.unmodifiable(levels),
    sharpness: sharpness,
    enabled: enabled,
    references: deltas(previous?.references ?? defaultRefs),
    modes: deltas(previous?.modes ?? defaultModes),
  );
}

Av1Cdef? readAv1Cdef(Av1Bits bits, bool enabled, bool chroma) {
  if (!enabled) return null;
  final damping = bits.read(2) + 3;
  final count = 1 << bits.read(2);
  final y = <({int primary, int secondary})>[],
      uv = <({int primary, int secondary})>[];
  ({int primary, int secondary}) strength() {
    final primary = bits.read(4), secondary = bits.read(2);
    return (primary: primary, secondary: secondary == 3 ? 4 : secondary);
  }

  for (var i = 0; i < count; i++) {
    y.add(strength());
    if (chroma) uv.add(strength());
  }
  return (damping: damping, y: List.unmodifiable(y), uv: List.unmodifiable(uv));
}

Av1Restoration? readAv1Restoration(
  Av1Bits bits,
  Av1SequenceHeader seq,
  bool enabled,
) {
  if (!enabled) return null;
  final types = [
    for (var i = 0; i < seq.color.planes; i++)
      Av1RestorationType.values[bits.read(2)],
  ];
  if (types.every((t) => t == Av1RestorationType.none)) return null;
  var shift = seq.tools.superblock128 ? 1 : 0;
  if (bits.flag()) {
    shift++;
    if (!seq.tools.superblock128 && bits.flag()) shift++;
  }
  final chroma =
      seq.color.subsamplingX == 1 &&
      seq.color.subsamplingY == 1 &&
      types.skip(1).any((t) => t != Av1RestorationType.none);
  final uv = chroma ? bits.read(1) : 0;
  return (
    types: List.unmodifiable(types),
    lumaUnit: 64 << shift,
    chromaUnit: 64 << (shift - uv),
  );
}

List<Av1GlobalMotion> readAv1GlobalMotion(
  Av1Bits bits,
  bool intra,
  bool highPrecision,
  List<Av1GlobalMotion>? previous,
) {
  Av1GlobalMotion motion(int i) {
    if (intra || !bits.flag()) return _identity;
    final type = bits.flag()
        ? Av1GlobalMotionType.rotZoom
        : bits.flag()
        ? Av1GlobalMotionType.translation
        : Av1GlobalMotionType.affine;
    final prior = previous?[i].matrix ?? _identity.matrix;
    final matrix = List.of(_identity.matrix);
    int param(int index, int absoluteBits, int shift) {
      final offset = index % 3 == 2 ? 65536 : 0;
      final r = (prior[index] - offset) >> shift;
      final mx = 1 << absoluteBits;
      return (_subexp(bits, 2 * mx + 1, r + mx) - mx) * (1 << shift) + offset;
    }

    if (type == Av1GlobalMotionType.translation) {
      final precision = highPrecision ? 0 : 1;
      matrix[0] = param(0, 9 - precision, 13 + precision);
      matrix[1] = param(1, 9 - precision, 13 + precision);
    } else {
      matrix[2] = param(2, 12, 1);
      matrix[3] = param(3, 12, 1);
      matrix[4] = type == Av1GlobalMotionType.affine
          ? param(4, 12, 1)
          : -matrix[3];
      matrix[5] = type == Av1GlobalMotionType.affine
          ? param(5, 12, 1)
          : matrix[2];
      matrix[0] = param(0, 12, 10);
      matrix[1] = param(1, 12, 10);
    }
    return (type: type, matrix: List.unmodifiable(matrix));
  }

  return List.unmodifiable(List.generate(7, motion));
}

int _subexp(Av1Bits bits, int count, int reference) {
  var base = 0, value = 0;
  for (var i = 0; ; i++) {
    final width = i < 2 ? 3 : i + 2;
    final range = 1 << width;
    if (count <= base + 3 * range) {
      value = base + bits.uniform(count - base);
      break;
    }
    if (!bits.flag()) {
      value = base + bits.read(width);
      break;
    }
    base += range;
  }
  int recenter(int r) {
    if (value > 2 * r) return value;
    return value.isOdd ? r - ((value + 1) >> 1) : r + (value >> 1);
  }

  return 2 * reference <= count
      ? recenter(reference)
      : count - 1 - recenter(count - 1 - reference);
}

typedef Av1GrainPoint = ({int value, int scaling});
typedef Av1GrainChroma = ({
  List<Av1GrainPoint> points,
  List<int> coefficients,
  int multiplier,
  int lumaMultiplier,
  int offset,
});
typedef Av1FilmGrain = ({
  int seed,
  List<Av1GrainPoint> luma,
  List<int> lumaCoefficients,
  bool chromaFromLuma,
  Av1GrainChroma cb,
  Av1GrainChroma cr,
  int scalingShift,
  int lag,
  int coefficientShift,
  int grainShift,
  bool overlap,
  bool restrictedRange,
});

Av1FilmGrain? readAv1FilmGrain(
  Av1Bits bits,
  Av1SequenceHeader seq, {
  required bool visible,
  required bool inter,
  required Av1FilmGrain? Function(int) fromReference,
}) {
  if (!seq.filmGrain || !visible || !bits.flag()) return null;
  final seed = bits.read(16);
  if (inter && !bits.flag()) {
    final source = fromReference(bits.read(3));
    // A reference that reset its grain parameters contributes no grain.
    if (source == null) return null;
    return (
      seed: seed,
      luma: source.luma,
      lumaCoefficients: source.lumaCoefficients,
      chromaFromLuma: source.chromaFromLuma,
      cb: source.cb,
      cr: source.cr,
      scalingShift: source.scalingShift,
      lag: source.lag,
      coefficientShift: source.coefficientShift,
      grainShift: source.grainShift,
      overlap: source.overlap,
      restrictedRange: source.restrictedRange,
    );
  }

  List<Av1GrainPoint> points(int max) {
    final count = bits.read(4);
    if (count > max)
      throw const FormatException('Invalid AV1 grain point count');
    final result = <Av1GrainPoint>[];
    for (var i = 0; i < count; i++) {
      final value = bits.read(8), scaling = bits.read(8);
      if (result.isNotEmpty && value <= result.last.value)
        throw const FormatException('Unordered AV1 grain points');
      result.add((value: value, scaling: scaling));
    }
    return List.unmodifiable(result);
  }

  final y = points(14), color = seq.color;
  final chromaFromLuma = !color.monochrome && bits.flag();
  final is420 = color.subsamplingX == 1 && color.subsamplingY == 1;
  final readChroma =
      !color.monochrome && !chromaFromLuma && (!is420 || y.isNotEmpty);
  final cb = readChroma ? points(10) : const <Av1GrainPoint>[];
  final cr = readChroma ? points(10) : const <Av1GrainPoint>[];
  if (is420 && cb.isEmpty != cr.isEmpty)
    throw const FormatException('Inconsistent AV1 chroma grain points');
  final scalingShift = bits.read(2) + 8, lag = bits.read(2);
  final count = 2 * lag * (lag + 1);
  List<int> coefficients(int size) =>
      List.unmodifiable([for (var i = 0; i < size; i++) bits.read(8) - 128]);
  final yCoefficients = coefficients(y.isEmpty ? 0 : count);
  final chromaCount = count + (y.isEmpty ? 0 : 1);
  final cbCoefficients = coefficients(
    cb.isNotEmpty || chromaFromLuma ? chromaCount : 0,
  );
  final crCoefficients = coefficients(
    cr.isNotEmpty || chromaFromLuma ? chromaCount : 0,
  );
  final coefficientShift = bits.read(2) + 6, grainShift = bits.read(2);

  Av1GrainChroma chroma(List<Av1GrainPoint> points, List<int> ar) => (
    points: points,
    coefficients: ar,
    multiplier: points.isEmpty ? 0 : bits.read(8) - 128,
    lumaMultiplier: points.isEmpty ? 0 : bits.read(8) - 128,
    offset: points.isEmpty ? 0 : bits.read(9) - 256,
  );

  return (
    seed: seed,
    luma: y,
    lumaCoefficients: yCoefficients,
    chromaFromLuma: chromaFromLuma,
    cb: chroma(cb, cbCoefficients),
    cr: chroma(cr, crCoefficients),
    scalingShift: scalingShift,
    lag: lag,
    coefficientShift: coefficientShift,
    grainShift: grainShift,
    overlap: bits.flag(),
    restrictedRange: bits.flag(),
  );
}
