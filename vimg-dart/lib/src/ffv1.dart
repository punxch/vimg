import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as image;

import 'yuv_image.dart';

part 'ffv1_range.dart';
part 'ffv1_rice.dart';

bool isFfv1Keyframe(Uint8List bytes) {
  if (bytes.length < 2) throw const FormatException('Truncated FFV1 frame');
  return (bytes[0] << 8 | bytes[1]) >= 0x7f80;
}

/// FFV1 version 3. Slice contexts are carried across frames in a GOP.
final class Ffv1Decoder {
  Ffv1Decoder(this.width, this.height, Uint8List? configuration)
    : _config = _Ffv1Configuration.read(configuration, width, height);

  final int width;
  final int height;
  final _Ffv1Configuration _config;
  var _previous = <(int, int, int, int), _SliceState>{};

  Ffv1Picture decode(Uint8List bytes) {
    final keyframe = isFfv1Keyframe(bytes);
    final previous = _previous;
    _previous = {};
    final config = _config;
    final covered = Uint8List(config.columns * config.rows);
    final slices = _findSlices(bytes, covered.length);
    final chromaWidth = _ceilShift(width, config.shiftX);
    final chromaHeight = _ceilShift(height, config.shiftY);
    final y = Uint16List(width * height);
    final cb = Uint16List(config.chroma ? chromaWidth * chromaHeight : 0);
    final cr = Uint16List(cb.length);
    final alpha = config.alpha ? Uint16List(y.length) : null;
    final next = <(int, int, int, int), _SliceState>{};
    for (final (start, end) in slices.reversed) {
      final range = _RangeDecoder(bytes, start, end);
      if (start == 0) range.bit(Uint8List.fromList([128]), 0);
      range.transitions = config.transitions;
      final header = _initialStates(32);
      final sx = range.symbol(header), sy = range.symbol(header);
      final sw = range.symbol(header) + 1, sh = range.symbol(header) + 1;
      if (sx + sw > config.columns || sy + sh > config.rows) {
        throw const FormatException('Invalid FFV1 slice bounds');
      }
      for (var row = sy; row < sy + sh; row++) {
        for (var column = sx; column < sx + sw; column++) {
          if (covered[row * config.columns + column]++ != 0) {
            throw const FormatException('Overlapping FFV1 slices');
          }
        }
      }
      final tables = List.generate(2 + (config.alpha ? 1 : 0), (_) {
        final index = range.symbol(header);
        if (index >= config.tables.length) {
          throw const FormatException('Invalid FFV1 quantization index');
        }
        return config.tables[index];
      });
      range.symbol(header); // Picture structure
      range.symbol(header); // Sample aspect numerator
      range.symbol(header); // Sample aspect denominator
      final position = (sx, sy, sw, sh);
      final state = keyframe
          ? _SliceState(tables, rice: config.rice)
          : previous[position] ??
                (throw const FormatException('Missing FFV1 slice context'));
      if (!state.tables.asMap().entries.every(
        (e) => e.value == tables[e.key],
      )) {
        throw const FormatException('FFV1 slice changed quantization tables');
      }
      next[position] = state;

      final rice = config.rice
          ? _RiceReader(bytes, range.riceStart(config.riceSentinel), end)
          : null;
      final x = sx * width ~/ config.columns;
      final top = sy * height ~/ config.rows;
      final w = (sx + sw) * width ~/ config.columns - x;
      final h = (sy + sh) * height ~/ config.rows - top;
      if (config.rgb) {
        final planes = [
          for (final index in [0, 1, 1, if (alpha != null) 2])
            _ScanLines(
              w,
              config.depth + 1,
              range,
              tables[index],
              state.contexts[index],
              rice: rice,
            ),
        ];
        final center = 1 << config.depth;
        final mask = center - 1;
        for (var row = 0; row < h; row++) {
          final samples = [for (final plane in planes) plane.decode()];
          var offset = (top + row) * width + x;
          for (var column = 2; column < w + 2; column++, offset++) {
            final b = samples[1][column] - center;
            final r = samples[2][column] - center;
            final g = samples[0][column] - ((b + r) >> 2);
            y[offset] = g & mask;
            cb[offset] = (g + b) & mask;
            cr[offset] = (g + r) & mask;
            if (alpha != null) alpha[offset] = samples[3][column] & mask;
          }
        }
      } else {
        void plane(
          Uint16List destination,
          int index,
          int stride,
          int shiftX,
          int shiftY,
        ) {
          final columns = _ceilShift(w, shiftX);
          final rows = _ceilShift(h, shiftY);
          if (rice != null) rice.runIndex = 0;
          final scan = _ScanLines(
            columns,
            config.depth,
            range,
            tables[index],
            state.contexts[index],
            rice: rice,
            signedPredictor: config.depth == 16,
          );
          var offset = (top >> shiftY) * stride + (x >> shiftX);
          for (var row = 0; row < rows; row++, offset += stride) {
            destination.setRange(offset, offset + columns, scan.decode(), 2);
          }
        }

        plane(y, 0, width, 0, 0);
        if (config.chroma) {
          plane(cb, 1, chromaWidth, config.shiftX, config.shiftY);
          plane(cr, 1, chromaWidth, config.shiftX, config.shiftY);
        }
        if (alpha != null) plane(alpha, 2, width, 0, 0);
      }
    }
    if (covered.contains(0)) {
      throw const FormatException('Incomplete FFV1 slice coverage');
    }
    _previous = next;
    return Ffv1Picture._(width, height, y, cb, cr, alpha, _config);
  }

  List<(int, int)> _findSlices(Uint8List bytes, int limit) {
    final result = <(int, int)>[];
    final footer = _config.crc ? 8 : 3;
    var end = bytes.length;
    while (end > 0) {
      final payloadEnd = end - footer;
      if (payloadEnd < 2 || result.length == limit) {
        throw const FormatException('Invalid FFV1 slice footer');
      }
      final size =
          bytes[payloadEnd] << 16 |
          bytes[payloadEnd + 1] << 8 |
          bytes[payloadEnd + 2];
      final start = payloadEnd - size;
      if (start < 0 || size < 2) {
        throw const FormatException('Invalid FFV1 slice size');
      }
      if (_config.crc &&
          (bytes[payloadEnd + 3] != 0 || _crc(bytes, start, end) != 0)) {
        throw const FormatException('Invalid FFV1 slice CRC or error status');
      }
      result.add((start, payloadEnd));
      end = start;
    }
    return result;
  }
}

final class Ffv1Picture {
  Ffv1Picture._(
    this.width,
    this.height,
    this.y,
    this.cb,
    this.cr,
    this.alpha,
    this._config,
  );

  final int width;
  final int height;
  final Uint16List y;
  final Uint16List cb;
  final Uint16List cr;
  final Uint16List? alpha;
  final _Ffv1Configuration _config;

  image.Image rgb({YuvImageScaler? scaler, int? matrix, bool? fullRange}) =>
      yuvImage(
        y: y,
        cb: cb,
        cr: cr,
        alpha: alpha,
        stride: width,
        chromaStride: _ceilShift(width, _config.shiftX),
        width: width,
        height: height,
        cropLeft: 0,
        cropTop: 0,
        matrix: _config.rgb ? 0 : matrix ?? 6,
        fullRange: _config.rgb || (fullRange ?? false),
        lumaDepth: _config.depth,
        chromaDepth: _config.depth,
        alphaDepth: _config.depth,
        subsamplingX: _config.shiftX,
        subsamplingY: _config.shiftY,
        scaler: scaler,
      );
}

final class _ScanLines {
  _ScanLines(
    this.width,
    this.bits,
    this.range,
    this.table,
    this.states, {
    this.rice,
    this.signedPredictor = false,
  }) : mask = (1 << bits) - 1,
       _current = Int32List(width + 3),
       _above = Int32List(width + 3),
       _twoUp = Int32List(width + 3);

  final int width;
  final int mask;
  final int bits;
  final _RiceReader? rice;
  final _RangeDecoder range;
  final _Quantization table;
  final _PlaneState states;
  final bool signedPredictor;
  Int32List _current;
  Int32List _above;
  Int32List _twoUp;

  Int32List decode() {
    final current = _current, above = _above, twoUp = _twoUp;
    current[1] = above[2];
    final rice = this.rice;
    rice?.startLine();
    final [a, b, c, d, e] = table.inputs;
    for (var i = 2; i < width + 2; i++) {
      final left = current[i - 1], top = above[i], topLeft = above[i - 1];
      final context =
          a[(left - topLeft) & 255] +
          b[(topLeft - top) & 255] +
          c[(top - above[i + 1]) & 255] +
          d[(current[i - 2] - left) & 255] +
          e[(twoUp[i] - top) & 255];
      final difference = rice == null
          ? range.symbol(
              states.range!,
              offset: context.abs() * 32,
              signed: true,
            )
          : rice.difference(states.rice!, context.abs(), bits, width + 2 - i);
      final prediction = signedPredictor
          ? _median(left.toSigned(16), top.toSigned(16), topLeft.toSigned(16))
          : _median(left, top, topLeft);
      current[i] =
          (prediction + (context < 0 ? -difference : difference)) & mask;
    }
    current[width + 2] = current[width + 1];
    _current = twoUp;
    _twoUp = above;
    _above = current;
    return current;
  }
}

int _median(int left, int top, int topLeft) =>
    (left + top - topLeft).clamp(math.min(left, top), math.max(left, top));

int _ceilShift(int value, int shift) => (value + (1 << shift) - 1) >> shift;

final class _SliceState {
  _SliceState(this.tables, {required bool rice})
    : contexts = [for (final table in tables) _PlaneState(table, rice: rice)];

  final List<_Quantization> tables;
  final List<_PlaneState> contexts;
}

final class _PlaneState {
  _PlaneState(_Quantization table, {required bool rice})
    : range = rice ? null : Uint8List.fromList(table.initial),
      rice = rice ? List.filled(table.initial.length ~/ 32, null) : null;

  final Uint8List? range;
  final List<_RiceContext?>? rice;
}

final class _Quantization {
  _Quantization(this.inputs, int count) : initial = _initialStates(count * 32);

  final List<Int16List> inputs;
  final Uint8List initial;

  factory _Quantization.read(_RangeDecoder range) {
    var scale = 1;
    final inputs = List.generate(5, (_) {
      final table = Int16List(256);
      final state = _initialStates(32);
      var levels = 0;
      var start = 0;
      while (start < 128) {
        final end = start + range.symbol(state) + 1;
        if (end > 128)
          throw const FormatException('Invalid FFV1 quantization run');
        table.fillRange(start, end, scale * levels);
        start = end;
        levels++;
      }
      for (var value = 1; value < 128; value++) {
        table[256 - value] = -table[value];
      }
      table[128] = -table[127];
      scale *= 2 * levels - 1;
      if (scale > 32768) {
        throw const FormatException('Too many FFV1 contexts');
      }
      return table;
    });
    return _Quantization(inputs, (scale + 1) ~/ 2);
  }
}

final class _Ffv1Configuration {
  _Ffv1Configuration(
    this.depth,
    this.rgb,
    this.chroma,
    this.alpha,
    this.shiftX,
    this.shiftY,
    this.columns,
    this.rows,
    this.crc,
    this.rice,
    this.riceSentinel,
    this.transitions,
    this.tables,
  );

  final int depth;
  final bool rgb;
  final bool chroma;
  final bool alpha;
  final int shiftX;
  final int shiftY;
  final int columns;
  final int rows;
  final bool crc;
  final bool rice;
  final bool riceSentinel;
  final List<int> transitions;
  final List<_Quantization> tables;

  factory _Ffv1Configuration.read(Uint8List? bytes, int width, int height) {
    if (bytes == null) {
      throw UnsupportedError('FFV1 without a version 3 configuration record');
    }
    if (bytes.length < 6 || _crc(bytes, 0, bytes.length) != 0) {
      throw const FormatException('Invalid FFV1 configuration CRC');
    }
    final range = _RangeDecoder(bytes, 0, bytes.length - 4);
    final state = _initialStates(32);
    final version = range.symbol(state);
    if (version != 3) throw UnsupportedError('FFV1 version $version');
    final microVersion = range.symbol(state);
    final coder = range.symbol(state);
    if (coder > 2) {
      throw UnsupportedError('FFV1 coder type $coder');
    }
    final transitions = coder != 2
        ? _standardTransitions
        : [
            0,
            for (var i = 1; i < 256; i++)
              (_standardTransitions[i] + range.symbol(state, signed: true)) &
                  255,
          ];
    final colorspace = range.symbol(state);
    final rawDepth = range.symbol(state);
    final depth = rawDepth == 0 ? 8 : rawDepth;
    final chroma = range.bit(state, 0) != 0;
    final shiftX = range.symbol(state), shiftY = range.symbol(state);
    final alpha = range.bit(state, 0) != 0;
    if (colorspace > 1 ||
        depth < 8 ||
        depth > 16 ||
        shiftX > 4 ||
        shiftY > 4 ||
        (colorspace == 1 && (!chroma || shiftX != 0 || shiftY != 0))) {
      throw const FormatException('Invalid FFV1 pixel format');
    }
    final columns = range.symbol(state) + 1;
    final rows = range.symbol(state) + 1;
    if (columns > width ||
        rows > height ||
        columns * rows > 1024 ||
        width > (64 * 1024 * 1024) ~/ height) {
      throw const FormatException('Invalid FFV1 dimensions or slice grid');
    }
    final count = range.symbol(state);
    if (count < 1 || count > 8) {
      throw const FormatException('Invalid FFV1 quantization table count');
    }
    final tables = List.generate(count, (_) => _Quantization.read(range));
    final deltaStates = _initialStates(32 * 32);
    for (final table in tables) {
      if (range.bit(state, 0) == 0) continue;
      final values = table.initial;
      for (var i = 0; i < values.length; i++) {
        final prediction = i < 32 ? 128 : values[i - 32];
        values[i] =
            prediction +
            range.symbol(deltaStates, offset: (i % 32) * 32, signed: true);
      }
    }
    final ec = range.symbol(state);
    if (ec > 1) throw UnsupportedError('FFV1 error correction mode $ec');
    if (microVersion >= 3) range.symbol(state); // Intra-only flag
    return _Ffv1Configuration(
      depth,
      colorspace == 1,
      chroma,
      alpha,
      shiftX,
      shiftY,
      columns,
      rows,
      ec == 1,
      coder == 0,
      microVersion >= 2,
      transitions,
      tables,
    );
  }
}
