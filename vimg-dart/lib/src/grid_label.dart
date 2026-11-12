import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as image;

import 'cantarell_font_data.dart';
import 'label_line_break_data.dart';

part 'label_font.dart';
part 'label_line_break.dart';
part 'label_raster.dart';

final _font = _LabelFont(
  ByteData.sublistView(
    Uint8List.fromList(gzip.decode(base64Decode(cantarellFontData))),
  ),
);
final _single = Float32List(1);

double _f32(double value) {
  _single[0] = value;
  return _single[0];
}

typedef _Ink = ({int x, int y, int alpha});

/// Rasterizes a bottom-right Cantarell label once for a grid's tile size.
final class GridLabel {
  GridLabel(int width, int height, String text) {
    if (text.isEmpty) return;
    final size = math.min(width, height).toDouble();
    final margin = _f32(size * _f32(0.01));
    final fontHeight = _f32(size * _f32(0.06));
    final scale = _f32(fontHeight / (_font.ascent - _font.descent));
    final ascent = _f32(_font.ascent * scale);
    final descent = _f32(_font.descent * scale);
    final lineHeight = _f32(
      _f32(ascent - descent) + _f32(_font.lineGap * scale),
    );
    final right = _f32(width - _f32(2 * margin));
    final bottom = _f32(height - margin);
    final (glyphs, advance) = _labelLine(text, width, scale);
    final start = _f32(right - advance);
    final baseline = _f32(ascent + _f32(bottom - lineHeight));
    _Bounds? bounds;
    for (final glyph in glyphs) {
      final outline = _font.outline(glyph.id);
      if (outline == null) continue;
      final x = _f32(start + glyph.x);
      final box = _glyphBounds(outline.bounds, x, baseline, scale);
      if (box.right <= box.left || box.bottom <= box.top) continue;
      bounds = bounds == null
          ? box
          : (
              left: math.min(bounds.left, box.left),
              top: math.min(bounds.top, box.top),
              right: math.max(bounds.right, box.right),
              bottom: math.max(bounds.bottom, box.bottom),
            );
      _ink.addAll(_glyphInk(outline, box, x, baseline, scale, width, height));
    }
    if (bounds == null) return;
    final inkLeft = math.max(bounds.left, _f32(right - width).floor());
    final inkTop = math.max(bounds.top, _f32(bottom - height).floor());
    final inkRight = math.min(bounds.right, right.ceil());
    final inkBottom = math.min(bounds.bottom, bottom.ceil());
    _background = (
      left: math.max(0, _f32(inkLeft - margin).truncate()),
      top: math.max(0, _f32(inkTop - margin).truncate()),
      right: math.min(width - 1, _f32(inkRight + margin).ceil()),
      bottom: math.min(height - 1, _f32(inkBottom + margin).ceil()),
    );
  }

  _Bounds? _background;
  final _ink = <_Ink>[];

  void paint(image.Image grid, int x, int y, {image.Image? source}) {
    final background = _background;
    if (background != null) {
      final (left: left, top: top, right: right, bottom: bottom) = background;
      for (var row = top; row <= bottom; row++) {
        for (var col = left; col <= right; col++) {
          if ((col == left || col == right) && (row == top || row == bottom)) {
            continue;
          }
          final pixel = grid.getPixel(x + col, y + row);
          pixel.setRgb(
            pixel.r * 77 ~/ 255,
            pixel.g * 77 ~/ 255,
            pixel.b * 77 ~/ 255,
          );
        }
      }
    }
    if (source == null) {
      for (final ink in _ink) {
        final pixel = grid.getPixel(x + ink.x, y + ink.y);
        final keep = 255 - ink.alpha;
        pixel.setRgb(
          pixel.r * keep ~/ 255 + ink.alpha,
          pixel.g * keep ~/ 255 + ink.alpha,
          pixel.b * keep ~/ 255 + ink.alpha,
        );
      }
    } else {
      _paintSourceOver(grid, x, y, source);
    }
  }

  void _paintSourceOver(image.Image grid, int x, int y, image.Image source) {
    final alphaAt = <int, int>{};
    for (final ink in _ink) {
      final pixel = grid.getPixel(x + ink.x, y + ink.y);
      final index = ink.y * source.width + ink.x;
      if (ink.alpha == 255) {
        pixel.setRgb(255, 255, 255);
        if (source.hasAlpha) alphaAt[index] = 255;
        continue;
      }
      final baseAlpha = source.hasAlpha
          ? alphaAt[index] ?? source.getPixel(ink.x, ink.y).a.toInt()
          : 255;
      final foreground = _f32(ink.alpha / 255);
      final background = _f32(baseAlpha / 255);
      final keep = _f32(1 - foreground);
      final alpha = _f32(
        _f32(background + foreground) - _f32(background * foreground),
      );
      int blend(num channel) {
        final premultiplied = _f32(_f32(channel / 255) * background);
        final color = _f32(foreground + _f32(premultiplied * keep));
        return _f32(_f32(color / alpha) * 255).toInt().clamp(0, 255);
      }

      pixel.setRgb(blend(pixel.r), blend(pixel.g), blend(pixel.b));
      if (source.hasAlpha) alphaAt[index] = _f32(alpha * 255).toInt();
    }
  }
}

typedef _PositionedGlyph = ({int id, double x});

(List<_PositionedGlyph>, double) _labelLine(
  String text,
  int width,
  double scale,
) {
  final runes = text.runes.toList(growable: false);
  final glyphs = <_PositionedGlyph>[];
  var start = 0;
  var caret = 0.0, rightmost = 0.0;
  for (final boundary in _lineBreaks(runes)) {
    final word = <_PositionedGlyph>[];
    var advance = 0.0, visibleAdvance = 0.0;
    for (var i = start; i < boundary.end; i++) {
      final rune = runes[i];
      if (rune < 0x20 || (rune >= 0x7f && rune <= 0x9f)) continue;
      final id = _font.glyphId(rune);
      word.add((id: id, x: _f32(caret + advance)));
      advance = _f32(advance + _f32(_font.advance(id) * scale));
      if (!_isSpace(rune)) visibleAdvance = advance;
    }
    final edge = _f32(caret + (boundary.hard ? advance : visibleAdvance));
    if (start > 0 && edge > width && edge - width > width * 1.2e-7) break;
    glyphs.addAll(word);
    caret = _f32(caret + advance);
    rightmost = edge;
    start = boundary.end;
    if (boundary.hard) break;
  }
  return (glyphs, rightmost);
}

bool _isSpace(int rune) => switch (rune) {
  0x20 ||
  0xa0 ||
  0x1680 ||
  0x2028 ||
  0x2029 ||
  0x202f ||
  0x205f ||
  0x3000 => true,
  >= 0x2000 && <= 0x200a => true,
  _ => false,
};
