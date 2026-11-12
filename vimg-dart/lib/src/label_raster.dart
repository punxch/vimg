part of 'grid_label.dart';

_Bounds _glyphBounds(_Bounds design, double x, double y, double scale) {
  final ix = x.truncate(), iy = y.truncate();
  final fx = x - ix, fy = y - iy;
  return (
    left: ix + _f32(_f32(design.left * scale) + fx).floor(),
    top: iy + _f32(_f32(-design.top * scale) + fy).floor(),
    right: ix + _f32(_f32(design.right * scale) + fx).ceil(),
    bottom: iy + _f32(_f32(-design.bottom * scale) + fy).ceil(),
  );
}

Iterable<_Ink> _glyphInk(
  _GlyphOutline outline,
  _Bounds bounds,
  double x,
  double y,
  double scale,
  int tileWidth,
  int tileHeight,
) sync* {
  final left = math.max(0, bounds.left);
  final top = math.max(0, bounds.top);
  final width = math.min(tileWidth, bounds.right) - left;
  final height = math.min(tileHeight, bounds.bottom) - top;
  if (width <= 0 || height <= 0) return;
  final offsetX = _f32(x - left), offsetY = _f32(y - top);
  final raster = _Coverage(width, height);
  _Point position(_Point p) => (
    x: _f32(_f32(p.x * scale) + offsetX),
    y: _f32(_f32(-p.y * scale) + offsetY),
  );
  for (final edge in outline.edges) {
    final from = position(edge.from), to = position(edge.to);
    if (edge.control case final control?) {
      raster.quadratic(from, position(control), to);
    } else {
      raster.line(from, to);
    }
  }
  for (var i = 0; i < raster.area.length; i++) {
    final alpha = _f32(raster.area[i].abs() * 255).truncate().clamp(0, 255);
    if (alpha > 0)
      yield (x: left + i % width, y: top + i ~/ width, alpha: alpha);
  }
}

final class _Coverage {
  _Coverage(this.width, this.height) : area = Float64List(width * height);

  final int width, height;
  final Float64List area;

  void quadratic(_Point from, _Point control, _Point to) {
    final dx = _f32(_f32(from.x - 2 * control.x) + to.x);
    final dy = _f32(_f32(from.y - 2 * control.y) + to.y);
    final deviation = _f32(_f32(dx * dx) + _f32(dy * dy));
    final segments = deviation < _f32(0.333)
        ? 1
        : 1 + math.sqrt(math.sqrt(3 * deviation)).floor();
    final step = _f32(1 / segments);
    var t = 0.0;
    var previous = from;
    for (var i = 1; i < segments; i++) {
      t = _f32(t + step);
      final next = _lerp(_lerp(from, control, t), _lerp(control, to, t), t);
      line(previous, next);
      previous = next;
    }
    line(previous, to);
  }

  void line(_Point from, _Point to) {
    if ((from.y - to.y).abs() <= 1.1920929e-7) return;
    final down = from.y < to.y;
    final start = down ? from : to;
    final end = down ? to : from;
    final slope = (end.x - start.x) / (end.y - start.y);
    final bottom = math.min(height, end.y.ceil());
    for (var row = math.max(0, start.y.floor()); row < bottom; row++) {
      final top = math.max(row.toDouble(), start.y);
      final span = math.min(row + 1.0, end.y) - top;
      final atTop = start.x + (top - start.y) * slope;
      final atBottom = atTop + span * slope;
      final left = math.min(atTop, atBottom), right = math.max(atTop, atBottom);
      final signedHeight = down ? span : -span;
      final offset = row * width;
      // Integrate the fraction of each pixel lying to the right of this edge.
      // Opposite edge directions subtract, so holes require no special case.
      for (var col = math.max(0, left.floor()); col < width; col++) {
        final near = col + 1.0 - right;
        if (near >= 1) {
          area[offset + col] += signedHeight;
          continue;
        }
        final far = col + 1.0 - left;
        final covered = right - left < 1e-10
            ? far.clamp(0.0, 1.0)
            : (_integral(far) - _integral(near)) / (right - left);
        area[offset + col] += signedHeight * covered;
      }
    }
  }
}

double _integral(double x) => switch (x) {
  <= 0 => 0.0,
  < 1 => 0.5 * x * x,
  _ => x - 0.5,
};

_Point _lerp(_Point a, _Point b, double t) => (
  x: _f32(a.x + _f32(t * _f32(b.x - a.x))),
  y: _f32(a.y + _f32(t * _f32(b.y - a.y))),
);
