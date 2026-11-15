part of 'yuv_image.dart';

bool _filterFlag(String? value, String name) => switch (value) {
  null || '0' || 'false' || 'no' || 'off' => false,
  '1' || 'true' || 'yes' || 'on' => true,
  _ => throw FormatException('Invalid $name boolean'),
};

double _aspectRatio(String value) {
  final ratio = value.split(RegExp(r'[:/]'));
  final numerator = double.tryParse(ratio.first);
  final denominator = ratio.length == 2 ? double.tryParse(ratio.last) : 1.0;
  if (ratio.length > 2 ||
      numerator == null ||
      denominator == null ||
      !numerator.isFinite ||
      !denominator.isFinite ||
      numerator < 0 ||
      denominator <= 0) {
    throw FormatException('Invalid video filter aspect ratio: $value');
  }
  return numerator / denominator;
}

final class _SetAspect implements _SpatialFilter {
  factory _SetAspect(String? source, {required bool display}) {
    final name = display ? 'dar' : 'sar';
    final options = _filterOptions(
      source,
      [name, 'max'],
      {'ratio': name, 'r': name},
    );
    final maximum = int.tryParse(options['max'] ?? '100');
    if (maximum == null || maximum < 1 || maximum > 2147483647) {
      throw const FormatException('Invalid aspect ratio reduction limit');
    }
    final ratio = options[name] ?? '0';
    final expression = RegExp(r'^\d+:\d+$').hasMatch(ratio)
        ? parseFilterExpression(ratio.replaceFirst(':', '/'), const {})
        : parseFilterExpression(ratio, {..._dimensionVariables, 'w', 'h'});
    return _SetAspect._(expression, display, maximum);
  }

  const _SetAspect._(this.expression, this.display, this.maximum);
  final FilterExpression expression;
  final bool display;
  final int maximum;

  @override
  _VideoPlanes apply(_VideoPlanes frame) {
    final values = frame.variables
      ..['w'] = frame.width.toDouble()
      ..['h'] = frame.height.toDouble();
    final ratio = expression(values);
    if (!ratio.isFinite || ratio < 0 || ratio > 2147483647) {
      throw const FormatException('Invalid video filter aspect ratio');
    }
    final reduced = ratio == 0
        ? 1.0
        : captureRational(ratio, maximum: maximum).value;
    final sar = display && ratio != 0
        ? reduced * frame.height / frame.width
        : reduced;
    return _VideoPlanes(
      frame.planes,
      frame.subX,
      frame.subY,
      matrix: frame.matrix,
      fullRange: frame.fullRange,
      packedRgb: frame.packedRgb,
      sampleAspect: sar,
      alpha: frame.alpha,
    );
  }
}

final class _Pad implements _SpatialFilter {
  factory _Pad(String? source) {
    final options = _filterOptions(
      source,
      ['w', 'h', 'x', 'y', 'color', 'eval', 'aspect'],
      {'width': 'w', 'height': 'h'},
    );
    if (!const {null, '0', '1', 'init', 'frame'}.contains(options['eval'])) {
      throw const FormatException('Invalid pad evaluation mode');
    }
    final aspect = _aspectRatio(options['aspect'] ?? '0');
    const offsetVariables = {..._dimensionVariables, 'x', 'y'};
    return _Pad._(
      parseFilterExpression(options['w'] ?? 'iw', _dimensionVariables),
      parseFilterExpression(options['h'] ?? 'ih', _dimensionVariables),
      parseFilterExpression(options['x'] ?? '0', offsetVariables),
      parseFilterExpression(options['y'] ?? '0', offsetVariables),
      _PaintColor.parse(options['color'] ?? 'black'),
      aspect,
    );
  }

  const _Pad._(
    this.width,
    this.height,
    this.x,
    this.y,
    this.color,
    this.aspect,
  );
  final FilterExpression width, height, x, y;
  final _PaintColor color;
  final double aspect;

  @override
  _VideoPlanes apply(_VideoPlanes frame) {
    final vars = frame.variables;
    final firstWidth = width(vars);
    vars['ow'] = vars['out_w'] = firstWidth.isFinite
        ? firstWidth.truncateToDouble()
        : double.nan;
    var h = _dimension(height(vars));
    if (h == 0) h = frame.height;
    vars['oh'] = vars['out_h'] = h.toDouble();
    var w = _dimension(width(vars));
    if (w == 0) w = frame.width;
    if (aspect > 0) {
      final adjusted = aspect / frame.sampleAspect;
      final desiredHeight = _dimension((w / adjusted).roundToDouble());
      if (desiredHeight > h) {
        h = desiredHeight;
      } else {
        w = _dimension((h * adjusted).roundToDouble());
      }
    }
    vars['ow'] = vars['out_w'] = w.toDouble();
    vars['oh'] = vars['out_h'] = h.toDouble();
    vars['x'] = x(vars);
    var top = _dimension(vars['y'] = y(vars));
    var left = _dimension(x(vars));
    if (left < 0 || left + frame.width > w) left = (w - frame.width) ~/ 2;
    if (top < 0 || top + frame.height > h) top = (h - frame.height) ~/ 2;
    w = w >> frame.subX << frame.subX;
    h = h >> frame.subY << frame.subY;
    left = left >> frame.subX << frame.subX;
    top = top >> frame.subY << frame.subY;
    _checkFilterSize(w, h);
    if (left < 0 ||
        top < 0 ||
        left + frame.width > w ||
        top + frame.height > h) {
      throw const FormatException(
        'Padded dimensions cannot contain the source frame',
      );
    }
    if (w == frame.width && h == frame.height) return frame;

    return frame.mapComponents((plane, sx, sy, component) {
      final paddedWidth = w >> sx, paddedHeight = h >> sy;
      final samples = _paintSamples(plane.depth, paddedWidth * paddedHeight);
      samples.fillRange(
        0,
        samples.length,
        color.sample(frame, component, plane.depth),
      );
      final px = left >> sx, py = top >> sy;
      for (var row = 0; row < plane.height; row++) {
        final destination = (py + row) * paddedWidth + px;
        final source = plane.offset + row * plane.rowStep;
        if (plane.columnStep == 1) {
          samples.setRange(
            destination,
            destination + plane.width,
            plane.samples,
            source,
          );
        } else {
          for (var col = 0; col < plane.width; col++) {
            samples[destination + col] =
                plane.samples[source + col * plane.columnStep];
          }
        }
      }
      return _FilterPlane(
        samples,
        paddedWidth,
        paddedHeight,
        plane.depth,
        rowStep: paddedWidth,
      );
    });
  }
}

final class _DrawBox implements _SpatialFilter {
  factory _DrawBox(String? source) {
    final options = _filterOptions(
      source,
      ['x', 'y', 'w', 'h', 'color', 't', 'replace'],
      {'width': 'w', 'height': 'h', 'c': 'color', 'thickness': 't'},
    );
    const variables = {
      'iw',
      'ih',
      'in_w',
      'in_h',
      'sar',
      'dar',
      'hsub',
      'vsub',
      'x',
      'y',
      'w',
      'h',
      't',
      'fill',
    };
    final color = options['color'] ?? 'black';
    return _DrawBox._(
      [
        for (final (key, fallback) in [
          ('x', '0'),
          ('y', '0'),
          ('w', '0'),
          ('h', '0'),
          ('t', '3'),
        ])
          parseFilterExpression(options[key] ?? fallback, variables),
      ],
      color == 'invert' ? null : _PaintColor.parse(color),
      _filterFlag(options['replace'], 'drawbox replace'),
    );
  }

  const _DrawBox._(this.geometry, this.color, this.replace);
  final List<FilterExpression> geometry;
  final _PaintColor? color;
  final bool replace;

  @override
  _VideoPlanes apply(_VideoPlanes frame) {
    final vars = frame.variables
      ..['hsub'] = frame.subX.toDouble()
      ..['vsub'] = frame.subY.toDouble();
    const names = ['x', 'y', 'w', 'h', 't'];
    final values = List<double>.filled(5, 0);
    // Expressions may depend on one another, so use the evaluated values
    // from the preceding pass before validating the final geometry.
    for (var pass = 0; pass < 6; pass++) {
      for (var i = 0; i < names.length; i++) {
        vars['fill'] = switch (i) {
          0 => frame.width.toDouble(),
          1 => frame.height.toDouble(),
          2 => frame.width - values[0],
          3 => frame.height - values[1],
          _ => 2147483647.0,
        };
        final value = geometry[i](vars);
        final evaluated = value.isFinite ? value.truncateToDouble() : value;
        values[i] = vars[names[i]] = evaluated;
      }
    }
    final [x, y, w, h, thickness] = values.map(_dimension).toList();
    final right = x + (w > 0 ? w : frame.width);
    final bottom = y + (h > 0 ? h : frame.height);
    final left = math.max(0, x), top = math.max(0, y);
    final endX = math.min(frame.width, right),
        endY = math.min(frame.height, bottom);
    final paint = color;
    final overwrite = replace && frame.alpha != null;
    if (thickness <= 0 ||
        endX <= left ||
        endY <= top ||
        (paint?.alpha == 0 && !overwrite))
      return frame;

    return frame.mapComponents((plane, sx, sy, component) {
      if (paint == null && (component == 3 || (!frame.rgb && component != 0)))
        return plane;
      if (component == 3 && !overwrite) return plane;
      final result = plane._copy();
      final samples = result.samples;
      final maximum = (1 << plane.depth) - 1;
      final target =
          paint?.sample(frame, component, plane.depth, box: true) ?? 0;
      final opacity = (paint?.alpha ?? 255) / 255;
      for (var row = top; row < endY; row++) {
        final offset = (row >> sy) * plane.width;
        final edge = row - y < thickness || bottom - row <= thickness;
        for (var col = left; col < endX; col++) {
          if (!edge && col - x >= thickness && right - col > thickness)
            continue;
          final index = offset + (col >> sx);
          // A subsampled chroma sample is blended once per covered luma pixel.
          final old = samples[index];
          samples[index] = paint == null
              ? maximum - old
              : overwrite || opacity == 1
              ? target
              : ((1 - opacity) * old + opacity * target).toInt();
        }
      }
      return result;
    });
  }
}

final class _Negate implements _SpatialFilter {
  factory _Negate(String? source) {
    final options = _filterOptions(source, ['components', 'negate_alpha']);
    final alpha = _filterFlag(options['negate_alpha'], 'negate_alpha');
    final value = options['components'];
    if (value == null) return _Negate._(null, alpha);
    const flags = {'r': 1, 'g': 2, 'b': 4, 'a': 8, 'y': 16, 'u': 32, 'v': 64};
    var mask = value.startsWith('+') || value.startsWith('-') ? 0x77 : 0;
    var position = 0;
    final token = RegExp(r'([+-]?)([a-z]+|0x[0-9a-fA-F]+|\d+)');
    while (position < value.length) {
      final entry = token.matchAsPrefix(value, position);
      if (entry == null || (position > 0 && entry[1]!.isEmpty)) {
        throw FormatException('Invalid negate components: $value');
      }
      final bits = flags[entry[2]] ?? int.tryParse(entry[2]!);
      if (bits == null || bits < 0 || bits > 127) {
        throw FormatException('Invalid negate components: $value');
      }
      mask = entry[1] == '-' ? mask & ~bits : mask | bits;
      position = entry.end;
    }
    if (mask == 0) throw FormatException('Invalid negate components: $value');
    return _Negate._(mask == 0x77 ? null : mask, alpha);
  }

  const _Negate._(this.components, this.alpha);
  final int? components;
  final bool alpha;

  @override
  _VideoPlanes apply(_VideoPlanes frame) {
    final mask = components;
    final flags = frame.rgb ? const [2, 4, 1, 8] : const [16, 32, 64, 8];
    final available =
        (frame.rgb
            ? 7
            : frame.planes.length == 1
            ? 16
            : 112) |
        (frame.alpha == null ? 0 : 8);
    if (mask != null && mask & ~available != 0) {
      throw const FormatException(
        'Requested negate components are unavailable',
      );
    }
    return frame.mapComponents((plane, _, _, index) {
      final active = mask == null
          ? index != 3 || alpha
          : mask & flags[index] != 0;
      if (!active) return plane;
      final maximum = (1 << plane.depth) - 1;
      return plane._copy((sample) => maximum - sample);
    });
  }
}

List<int> _paintSamples(int depth, int length) =>
    depth <= 8 ? Uint8List(length) : Uint16List(length);

final class _PaintColor {
  const _PaintColor(this.red, this.green, this.blue, this.alpha);
  final int red, green, blue, alpha;

  factory _PaintColor.parse(String value) {
    final parts = value.split('@');
    if (parts.length > 2) throw FormatException('Invalid filter color: $value');
    final name = parts.first.toLowerCase();
    final hex = name.startsWith('#')
        ? name.substring(1)
        : name.startsWith('0x')
        ? name.substring(2)
        : name;
    int? rgb = _namedFilterColors[name];
    var alpha = 255;
    if (rgb == null && RegExp(r'^(?:[0-9a-f]{6}|[0-9a-f]{8})$').hasMatch(hex)) {
      rgb = int.parse(hex, radix: 16);
      if (hex.length == 8) {
        alpha = rgb & 255;
        rgb >>= 8;
      }
    }
    if (name == 'transparent' || name == 'none') {
      rgb = 0;
      alpha = 0;
    }
    if (rgb == null) throw FormatException('Invalid filter color: $value');
    if (parts.length == 2) {
      final opacity = parts.last.toLowerCase();
      final parsed = opacity.startsWith('0x')
          ? int.tryParse(opacity)?.toDouble()
          : (double.tryParse(opacity) ?? double.nan) * 255;
      if (parsed == null || !parsed.isFinite || parsed < 0 || parsed > 255) {
        throw FormatException('Invalid filter color opacity: $value');
      }
      alpha = parsed.toInt();
    }
    return _PaintColor(rgb >> 16, (rgb >> 8) & 255, rgb & 255, alpha);
  }

  int sample(_VideoPlanes frame, int component, int depth, {bool box = false}) {
    final maximum = (1 << depth) - 1;
    if (component == 3) return (alpha * maximum + 127) ~/ 255;
    if (frame.rgb) {
      final value = switch (component) {
        0 => green,
        1 => blue,
        _ => red,
      };
      return (value * maximum + 127) ~/ 255;
    }
    if (box && depth == 8) {
      // drawbox uses the limited-range BT.601 integer drawing coefficients.
      return switch (component) {
        0 => ((263 * red + 516 * green + 100 * blue + 512) >> 10) + 16,
        1 => ((-152 * red - 298 * green + 450 * blue + 511) >> 10) + 128,
        _ => ((450 * red - 377 * green - 73 * blue + 511) >> 10) + 128,
      };
    }
    final (kr, kb) = switch (box ? 6 : frame.matrix) {
      1 => (0.2126, 0.0722),
      4 => (0.30, 0.11),
      7 => (0.212, 0.087),
      9 || 10 => (0.2627, 0.0593),
      _ => (0.299, 0.114),
    };
    final y = kr * red + (1 - kr - kb) * green + kb * blue;
    final chroma = component != 0;
    final value = switch (component) {
      0 => y / 255,
      1 => (blue - y) / (510 * (1 - kb)),
      _ => (red - y) / (510 * (1 - kr)),
    };
    final full = !box && frame.fullRange;
    final normalized = full
        ? value + (chroma ? 0.5 : 0)
        : (value * (chroma ? 224 : 219) + (chroma ? 128 : 16)) / 255;
    return (normalized * maximum).round().clamp(0, maximum);
  }
}
