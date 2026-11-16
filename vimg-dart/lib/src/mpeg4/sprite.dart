part of 'syntax.dart';

final _divxSpriteMarker = RegExp(r'^DivX500(?:Build|b)413(?!\d)');

typedef _Point = ({int x, int y});

final class Mpeg4Sprite {
  const Mpeg4Sprite._(this.points, this.accuracy, this.brightness);

  final int points, accuracy;
  final bool brightness;

  factory Mpeg4Sprite.read(Rbsp bits) {
    final points = bits.read(6);
    if (points > 3)
      throw const FormatException('Invalid MPEG-4 warping point count');
    return Mpeg4Sprite._(points, bits.read(2), bits.flag());
  }
}

/// A fixed-point map from output coordinates to reference coordinates.
final class Mpeg4Gmc {
  const Mpeg4Gmc._(
    this.accuracy,
    this.shift,
    this.luma,
    this.chroma,
    this.stepX,
    this.stepY,
    this.legacyDivx,
  );

  final int accuracy, shift;
  final _Point luma, chroma, stepX, stepY;
  final bool legacyDivx;

  int get scale => 2 << accuracy;
  bool get translation => shift == 0;

  factory Mpeg4Gmc.read(
    Rbsp bits,
    Mpeg4Volume volume, {
    required bool legacyDivx,
  }) {
    final sprite =
        volume.sprite ??
        (throw const FormatException('MPEG-4 sprite frame has no trajectory'));
    if (sprite.brightness)
      throw UnsupportedError('MPEG-4 sprite brightness changes');
    final points = [
      for (var i = 0; i < sprite.points; i++)
        _readTrajectoryPoint(bits, legacyDivx),
    ];
    final units = 2 << sprite.accuracy;
    final pointScale = legacyDivx ? 1 : units >> 1;
    final first = points.isEmpty ? (x: 0, y: 0) : points.first;
    final origin = (x: first.x * pointScale, y: first.y * pointScale);
    if (points.length <= 1) {
      return Mpeg4Gmc._(
        sprite.accuracy,
        0,
        origin,
        (
          x: (origin.x >> 1) | (origin.x & 1),
          y: (origin.y >> 1) | (origin.y & 1),
        ),
        (x: units, y: 0),
        (x: 0, y: units),
        legacyDivx,
      );
    }

    // Virtual reference points on power-of-two boundaries put horizontal
    // and vertical interpolation on the same fixed-point grid.
    final width = volume.width, height = volume.height;
    final virtualWidth = 1 << math.max(1, (width - 1).bitLength);
    final virtualHeight = 1 << (height - 1).bitLength;
    final precision = 3 - sprite.accuracy;
    final trajectoryScale = pointScale << precision;
    int virtualDelta(int start, int distance, int basis, int delta) {
      final numerator = start * distance + delta * trajectoryScale * basis;
      final bias = distance >> 1;
      return (numerator + (numerator < 0 ? -bias : bias)) ~/ distance - start;
    }

    final startX = origin.x << precision, startY = origin.y << precision;
    var horizontal = (
      x:
          16 * virtualWidth +
          virtualDelta(startX, width, virtualWidth, points[1].x),
      y: virtualDelta(startY, width, virtualWidth, points[1].y),
    );
    var vertical = (x: -horizontal.y, y: horizontal.x);
    var basis = virtualWidth;
    if (points.length == 3) {
      final sharedBasis = math.min(virtualWidth, virtualHeight);
      final xMultiplier = virtualHeight ~/ sharedBasis;
      final yMultiplier = virtualWidth ~/ sharedBasis;
      basis = virtualWidth * xMultiplier;
      vertical = (
        x:
            virtualDelta(startX, height, virtualHeight, points[2].x) *
            yMultiplier,
        y:
            (16 * virtualHeight +
                virtualDelta(startY, height, virtualHeight, points[2].y)) *
            yMultiplier,
      );
      horizontal = (
        x: horizontal.x * xMultiplier,
        y: horizontal.y * xMultiplier,
      );
    }
    final fixedScale = basis << precision;
    final fixedShift = fixedScale.bitLength - 1;
    final luma = (
      x: origin.x * fixedScale + (fixedScale >> 1),
      y: origin.y * fixedScale + (fixedScale >> 1),
    );
    // The chroma sample centres are halfway between luma sample centres.
    int chromaOffset(int source, int dx, int dy) =>
        (2 * fixedScale * source + dx + dy - 16 * basis + 2 * fixedScale) >> 2;
    final chroma = (
      x: chromaOffset(origin.x, horizontal.x, vertical.x),
      y: chromaOffset(origin.y, horizontal.y, vertical.y),
    );
    if (horizontal.x == units * fixedScale &&
        horizontal.y == 0 &&
        vertical.x == 0 &&
        vertical.y == units * fixedScale) {
      return Mpeg4Gmc._(
        sprite.accuracy,
        0,
        (x: luma.x >> fixedShift, y: luma.y >> fixedShift),
        (x: chroma.x >> fixedShift, y: chroma.y >> fixedShift),
        (x: units, y: 0),
        (x: 0, y: units),
        legacyDivx,
      );
    }
    return Mpeg4Gmc._(
      sprite.accuracy,
      fixedShift,
      luma,
      chroma,
      horizontal,
      vertical,
      legacyDivx,
    );
  }

  // Adjacent macroblocks and direct B-VOPs use the mean displacement
  // expressed in the local motion-vector units.
  _Point averageVector(int x, int y, int code, {required bool quarter}) {
    final extra = quarter ? 1 : 0;
    final max = 1 << (code + 4);
    int average(int offset, int dx, int dy) {
      if (translation) {
        if (legacyDivx && accuracy >= extra)
          return offset ~/ (1 << (accuracy - extra));
        return _roundMotion(offset << extra, accuracy);
      }
      var sum = 0;
      var row = offset + dx * (16 * x) + dy * (16 * y);
      for (var j = 0; j < 16; j++, row += dy) {
        var coordinate = row;
        for (var i = 0; i < 16; i++, coordinate += dx) {
          sum += coordinate >> shift;
        }
      }
      return _roundMotion(sum, accuracy + 8 - extra);
    }

    final identity = scale << shift;
    return (
      x: average(luma.x, stepX.x - identity, stepY.x).clamp(-max, max - 1),
      y: average(luma.y, stepX.y, stepY.y - identity).clamp(-max, max - 1),
    );
  }
}

int _roundMotion(int value, int shift) {
  if (shift == 0) return value;
  return (value + (1 << (shift - 1)) - (value < 0 ? 1 : 0)) >> shift;
}

_Point _readTrajectoryPoint(Rbsp bits, bool legacyDivx) {
  final x = _readTrajectoryComponent(bits);
  if (!legacyDivx) mpeg4Marker(bits);
  final y = _readTrajectoryComponent(bits);
  mpeg4Marker(bits);
  return (x: x, y: y);
}

int _readTrajectoryComponent(Rbsp bits) {
  final prefix = bits.read(2);
  if (prefix == 0) return 0;
  var length = ((prefix << 1) | bits.bit()) - 1;
  if (length == 6) {
    while (bits.flag()) {
      if (++length > 14)
        throw const FormatException('Invalid MPEG-4 trajectory VLC');
    }
  }
  final encoded = bits.read(length);
  return encoded < (1 << (length - 1)) ? encoded + 1 - (1 << length) : encoded;
}
