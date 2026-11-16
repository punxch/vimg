import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as image;

import 'yuv_image.dart';

part 'ffv1_bayer.dart';
part 'ffv1_range.dart';
part 'ffv1_rice.dart';
part 'ffv1_samples.dart';

bool isFfv1Keyframe(Uint8List bytes) {
  if (bytes.length < 2) throw const FormatException('Truncated FFV1 frame');
  return (bytes[0] << 8 | bytes[1]) >= 0x7f80;
}

/// FFV1 video. Contexts are carried across frames in a GOP.
final class Ffv1Decoder {
  Ffv1Decoder(this.width, this.height, Uint8List? configuration)
    : _record = configuration == null
          ? null
          : _Ffv1Configuration.readRecord(configuration, width, height) {
    if (width <= 0 || height <= 0 || width > (64 * 1024 * 1024) ~/ height) {
      throw const FormatException('Invalid FFV1 frame dimensions');
    }
  }

  final int width;
  final int height;
  final _Ffv1Configuration? _record;
  _Ffv1Configuration? _legacyConfiguration;
  var _previous = <(int, int, int, int), _SliceState>{};

  Ffv1Picture decode(Uint8List bytes) {
    final keyframe = isFfv1Keyframe(bytes);
    final previous = _previous;
    _previous = {};
    final record = _record;
    final legacyRange = record == null
        ? _RangeDecoder(bytes, 0, bytes.length)
        : null;
    final legacyConfiguration = _legacyConfiguration;
    _legacyConfiguration = null;
    legacyRange?.bit(_initialStates(1), 0);
    final config =
        record ??
        (keyframe
            ? _Ffv1Configuration.readParameters(
                legacyRange!,
                width,
                height,
                hasRecord: false,
              )
            : legacyConfiguration ??
                  (throw const FormatException('Missing FFV1 keyframe')));
    final grid = config.columns * config.rows;
    final covered = record == null ? null : Uint8List(grid);
    final slices = record == null
        ? [(0, bytes.length)]
        : _findSlices(bytes, grid, crcSeed: config.sliceCrcSeed);
    final chromaWidth = _ceilShift(width, config.shiftX);
    final chromaHeight = _ceilShift(height, config.shiftY);
    List<int> planeBuffer(int length) =>
        config.depth == 32 ? Uint32List(length) : Uint16List(length);
    final y = planeBuffer(width * height);
    final cb = planeBuffer(
      config.chroma && !config.bayer ? chromaWidth * chromaHeight : 0,
    );
    final cr = planeBuffer(cb.length);
    final alpha = config.alpha ? planeBuffer(y.length) : null;
    final next = <(int, int, int, int), _SliceState>{};
    for (final (start, end) in slices.reversed) {
      final range = legacyRange ?? _RangeDecoder(bytes, start, end);
      if (legacyRange == null && start == 0) range.bit(_initialStates(1), 0);
      range.transitions = config.transitions;
      final header = _sliceHeader(range, config, covered);
      final position = header.position;
      final tables = header.tables;
      final (sx, sy, sw, sh) = position;
      final state = keyframe || header.reset
          ? _SliceState(tables, rice: config.rice)
          : previous[position] ??
                (throw const FormatException('Missing FFV1 slice context'));
      if (!state.tables.asMap().entries.every(
        (e) => e.value == tables[e.key],
      )) {
        throw const FormatException('FFV1 slice changed quantization tables');
      }
      next[position] = state;

      final x = config.sliceCoordinate(
        width,
        sx,
        config.columns,
        config.shiftX,
      );
      final top = config.sliceCoordinate(
        height,
        sy,
        config.rows,
        config.shiftY,
      );
      final w =
          config.sliceCoordinate(
            width,
            sx + sw,
            config.columns,
            config.shiftX,
          ) -
          x;
      final h =
          config.sliceCoordinate(height, sy + sh, config.rows, config.shiftY) -
          top;
      if (w <= 0 || h <= 0) {
        throw const FormatException('Empty FFV1 slice');
      }
      final maps = header.remap == 0
          ? const <_SampleMap>[]
          : List.generate(
              1 + (config.chroma ? 2 : 0) + (config.alpha ? 1 : 0),
              (_) => _SampleMap.read(
                range,
                config.depth,
                w * h,
                flipSignOrder: header.remap == 2,
              ),
            );
      final rice = config.rice && !header.raw
          ? _RiceReader(bytes, range.riceStart(config.riceSentinel), end)
          : null;
      if (config.bayer) {
        _decodeBayerSlice(range, header, state, rice, y, width, (x, top, w, h));
        continue;
      }
      if (config.rgb) {
        final indices = [0, 1, 1, if (alpha != null) 2];
        final domain = 1 << config.depth;
        final domains = maps.isEmpty
            ? List.filled(indices.length, domain)
            : [for (final map in maps) map.samples.length];
        final bits = [for (final count in domains) (count - 1).bitLength];
        final center = domains[0];
        if (!header.raw) {
          bits[0] = bits.take(3).reduce(math.max);
          bits[1] = (center + domains[1] - 1).bitLength;
          bits[2] = (center + domains[2] - 1).bitLength;
          if (config.extraRgbBit) {
            bits[0]++;
            if (alpha != null) bits[3]++;
          }
        }
        final planes = [
          for (final (plane, index) in indices.indexed)
            _ScanLines(
              w,
              bits[plane],
              range,
              tables[index],
              state.contexts[index],
              rice: rice,
              raw: header.raw,
            ),
        ];
        final mask = domain - 1;
        // FFV1's 9–15-bit GBR exception uses blue as the RCT base.
        final blueFirst =
            config.depth > 8 && config.depth < 16 && alpha == null;
        for (var row = 0; row < h; row++) {
          final samples = [for (final plane in planes) plane.decode()];
          var offset = (top + row) * width + x;
          for (var column = 2; column < w + 2; column++, offset++) {
            var g = samples[0][column];
            var b = samples[1][column];
            var r = samples[2][column];
            if (!header.raw) {
              b -= center;
              r -= center;
              g -= (b * header.blueWeight + r * header.redWeight) >> 2;
              b += g;
              r += g;
            }
            if (maps.isNotEmpty) {
              g = maps[0].restore(g);
              b = maps[1].restore(b);
              r = maps[2].restore(r);
            }
            y[offset] = (blueFirst ? b : g) & mask;
            cb[offset] = (blueFirst ? g : b) & mask;
            cr[offset] = r & mask;
            if (alpha != null) {
              final a = samples[3][column];
              alpha[offset] = maps.isEmpty ? a & mask : maps[3].restore(a);
            }
          }
        }
      } else {
        void plane(
          List<int> destination,
          int index,
          int plane,
          int stride,
          int shiftX,
          int shiftY,
        ) {
          final columns = _ceilShift(w, shiftX);
          final rows = _ceilShift(h, shiftY);
          if (rice != null) rice.runIndex = 0;
          final map = maps.isEmpty ? null : maps[plane];
          final bits = map?.bits ?? config.depth;
          final scan = _ScanLines(
            columns,
            bits,
            range,
            tables[index],
            state.contexts[index],
            rice: rice,
            signedPredictor: bits == 16,
            raw: header.raw,
          );
          var offset = (top >> shiftY) * stride + (x >> shiftX);
          for (var row = 0; row < rows; row++, offset += stride) {
            final samples = scan.decode();
            if (map == null) {
              destination.setRange(offset, offset + columns, samples, 2);
            } else {
              for (var column = 0; column < columns; column++) {
                destination[offset + column] = map.restore(samples[column + 2]);
              }
            }
          }
        }

        plane(y, 0, 0, width, 0, 0);
        if (config.chroma) {
          plane(cb, 1, 1, chromaWidth, config.shiftX, config.shiftY);
          plane(cr, 1, 2, chromaWidth, config.shiftX, config.shiftY);
        }
        if (alpha != null) {
          plane(alpha, tables.length - 1, config.chroma ? 3 : 1, width, 0, 0);
        }
      }
    }
    if (covered?.contains(0) ?? false) {
      throw const FormatException('Incomplete FFV1 slice coverage');
    }
    _previous = next;
    if (record == null) _legacyConfiguration = config;
    return Ffv1Picture._(width, height, y, cb, cr, alpha, config);
  }

  _SliceHeader _sliceHeader(
    _RangeDecoder range,
    _Ffv1Configuration config,
    Uint8List? covered,
  ) {
    final planes =
        1 +
        (config.chroma || config.version < 4 ? 1 : 0) +
        (config.alpha ? 1 : 0) +
        (config.bayer ? 1 : 0);
    if (covered == null) {
      return _SliceHeader((
        0,
        0,
        1,
        1,
      ), List.filled(planes, config.tables.single));
    }
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
    final tables = List.generate(planes, (_) {
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
    if (config.version < 4) return _SliceHeader(position, tables);
    final reset = range.bit(header, 0) != 0;
    final mode = range.symbol(header);
    if (mode > 1) throw UnsupportedError('FFV1 slice coding mode $mode');
    final raw = mode == 1;
    final transform = (config.rgb || config.bayer) && !raw;
    final blueWeight = transform ? range.symbol(header) : 1;
    final redWeight = transform ? range.symbol(header) : 1;
    if (blueWeight + redWeight > 4) {
      throw const FormatException('Invalid FFV1 color transform');
    }
    final remap = config.microVersion >= 4 ? range.symbol(header) : 0;
    if (remap > 2 ||
        (remap == 2 && !config.floatingPoint) ||
        (remap != 0 && config.bayer)) {
      throw const FormatException('Invalid FFV1 sample remapping mode');
    }
    if (config.depth == 32 && remap == 0) {
      throw const FormatException('Missing FFV1 sample map');
    }
    return _SliceHeader(
      position,
      tables,
      reset: reset,
      raw: raw,
      remap: remap,
      blueWeight: blueWeight,
      redWeight: redWeight,
    );
  }

  List<(int, int)> _findSlices(
    Uint8List bytes,
    int limit, {
    required int? crcSeed,
  }) {
    final result = <(int, int)>[];
    final footer = crcSeed == null ? 3 : 8;
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
      if (crcSeed != null &&
          (bytes[payloadEnd + 3] != 0 ||
              _crc(bytes, start, end, seed: crcSeed) != crcSeed)) {
        throw const FormatException('Invalid FFV1 slice CRC or error status');
      }
      result.add((start, payloadEnd));
      end = start;
    }
    return result;
  }
}

final class _SliceHeader {
  _SliceHeader(
    this.position,
    this.tables, {
    this.reset = false,
    this.raw = false,
    this.remap = 0,
    this.blueWeight = 1,
    this.redWeight = 1,
  });

  final (int, int, int, int) position;
  final List<_Quantization> tables;
  final bool reset;
  final bool raw;
  final int remap;
  final int blueWeight;
  final int redWeight;
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

  /// Original sample codes, including IEEE floating-point bit patterns.
  final List<int> y;
  final List<int> cb;
  final List<int> cr;
  final List<int>? alpha;
  final _Ffv1Configuration _config;

  image.Image rgb({YuvImageScaler? scaler, int? matrix, bool? fullRange}) {
    final floating = _config.floatingPoint;
    final bayer = _config.bayer;
    final rgb = _config.rgb || bayer;
    final colorMatrix = rgb ? 0 : matrix ?? 6;
    final range = rgb || (fullRange ?? floating);
    final opacity = alpha;
    if (floating &&
        scaler != null &&
        scaler.filters != null &&
        (rgb || cb.isEmpty)) {
      Float32List plane(List<int> samples) =>
          _floatVideoSamples(samples, _config.depth);
      return scaler.filterFloatPlanes(
        [
          plane(y),
          if (cb.isNotEmpty) ...[plane(cb), plane(cr)],
        ],
        width: width,
        height: height,
        matrix: colorMatrix,
        fullRange: range,
        alpha: opacity == null ? null : plane(opacity),
      );
    }
    final depth = floating ? 16 : _config.depth;
    List<int> samples(List<int> source) =>
        floating ? _floatToVideoSamples(source, _config.depth) : source;
    final (luma, blue, red) = bayer
        ? _demosaicRggb(y, width, height)
        : (samples(y), samples(cb), samples(cr));
    final shiftX = bayer ? 0 : _config.shiftX;
    final shiftY = bayer ? 0 : _config.shiftY;
    return yuvImage(
      y: luma,
      cb: blue,
      cr: red,
      alpha: opacity == null ? null : samples(opacity),
      stride: width,
      chromaStride: _ceilShift(width, shiftX),
      width: width,
      height: height,
      cropLeft: 0,
      cropTop: 0,
      matrix: colorMatrix,
      fullRange: range,
      lumaDepth: depth,
      chromaDepth: depth,
      alphaDepth: depth,
      subsamplingX: shiftX,
      subsamplingY: shiftY,
      scaler: scaler,
    );
  }
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
    this.raw = false,
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
  final bool raw;
  Int32List _current;
  Int32List _above;
  Int32List _twoUp;

  Int32List decode() {
    final current = _current, above = _above, twoUp = _twoUp;
    if (bits == 0) return current;
    if (raw) {
      final state = _initialStates(1);
      for (var i = 2; i < width + 2; i++) {
        var sample = 0;
        for (var bit = 0; bit < bits; bit++) {
          state[0] = 128;
          sample = (sample << 1) | range.bit(state, 0);
        }
        current[i] = sample;
      }
      return current;
    }
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
    this.version,
    this.microVersion,
    this.depth,
    this.floatingPoint,
    this.colorspace,
    this.chroma,
    this.alpha,
    this.shiftX,
    this.shiftY,
    this.columns,
    this.rows,
    this.sliceCrcSeed,
    this.rice,
    this.riceSentinel,
    this.transitions,
    this.tables,
  );

  final int version;
  final int microVersion;
  final int depth;
  final bool floatingPoint;
  final int colorspace;
  final bool chroma;
  final bool alpha;
  final int shiftX;
  final int shiftY;
  final int columns;
  final int rows;
  final int? sliceCrcSeed;
  final bool rice;
  final bool riceSentinel;
  final List<int> transitions;
  final List<_Quantization> tables;

  bool get rgb => colorspace == 1;
  bool get bayer => colorspace == 2;
  bool get extraRgbBit => version < 4 || microVersion < 8;

  int sliceCoordinate(int length, int index, int count, int shift) {
    if (version < 4 || microVersion < 3) return length * index ~/ count;
    if (bayer) shift = math.max(1, shift);
    final units = _ceilShift(length, shift);
    final coordinate = ((2 * units * index + count) ~/ (2 * count)) << shift;
    return math.min(coordinate, length);
  }

  static _Ffv1Configuration readRecord(Uint8List bytes, int width, int height) {
    final seed = bytes.length < 6 ? null : _configurationCrcSeed(bytes);
    if (seed == null) {
      throw const FormatException('Invalid FFV1 configuration CRC');
    }
    final config = readParameters(
      _RangeDecoder(bytes, 0, bytes.length - 4),
      width,
      height,
      hasRecord: true,
    );
    if (seed != (config.sliceCrcSeed ?? 0)) {
      throw const FormatException('FFV1 configuration CRC mode mismatch');
    }
    return config;
  }

  static _Ffv1Configuration readParameters(
    _RangeDecoder range,
    int width,
    int height, {
    required bool hasRecord,
  }) {
    final state = _initialStates(32);
    final version = range.symbol(state);
    if (hasRecord ? version != 3 && version != 4 : version > 1) {
      throw UnsupportedError('FFV1 version $version');
    }
    final microVersion = hasRecord ? range.symbol(state) : 0;
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
    final rawDepth = version == 0 ? 8 : range.symbol(state);
    final depth = rawDepth == 0 ? 8 : rawDepth;

    if (depth > 16 && depth != 32) {
      throw UnsupportedError('FFV1 sample depth $depth');
    }
    final chroma = range.bit(state, 0) != 0;
    final shiftX = range.symbol(state), shiftY = range.symbol(state);
    final alpha = range.bit(state, 0) != 0;
    if (colorspace > 2 ||
        depth < 8 ||
        shiftX > 4 ||
        shiftY > 4 ||
        (colorspace == 1 && (!chroma || shiftX != 0 || shiftY != 0))) {
      throw const FormatException('Invalid FFV1 pixel format');
    }
    final bayer = colorspace == 2;
    if (bayer) {
      if (version < 4 ||
          depth != 16 ||
          !chroma ||
          alpha ||
          width.isOdd ||
          height.isOdd) {
        throw const FormatException('Invalid FFV1 Bayer format');
      }
      final order = range.symbol(state);
      if (order != 0) throw UnsupportedError('FFV1 Bayer order $order');
    }
    final columns = hasRecord ? range.symbol(state) + 1 : 1;
    final rows = hasRecord ? range.symbol(state) + 1 : 1;
    if (columns > width || rows > height || columns * rows > 1024) {
      throw const FormatException('Invalid FFV1 slice grid');
    }
    final count = hasRecord ? range.symbol(state) : 1;
    if (count < 1 || count > 8) {
      throw const FormatException('Invalid FFV1 quantization table count');
    }
    final tables = List.generate(count, (_) => _Quantization.read(range));
    int? sliceCrcSeed;
    var floatingPoint = false;
    if (hasRecord) {
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
      sliceCrcSeed = switch (ec) {
        0 => null,
        1 => 0,
        2 => _alternateCrcSeed,
        _ => throw UnsupportedError('FFV1 error correction mode $ec'),
      };
      if (microVersion >= 3 || version >= 4)
        range.symbol(state); // Intra-only flag
      if (version >= 4 && microVersion >= 4) {
        final floatingFlag = range.symbol(state);
        floatingPoint = !bayer && depth >= 16 && floatingFlag != 0;
      }
    }
    if (depth == 32 && (!floatingPoint || colorspace != 1)) {
      throw UnsupportedError('FFV1 32-bit sample format');
    }
    return _Ffv1Configuration(
      version,
      microVersion,
      depth,
      floatingPoint,
      colorspace,
      chroma,
      alpha,
      shiftX,
      shiftY,
      columns,
      rows,
      sliceCrcSeed,
      coder == 0,
      microVersion >= 2,
      transitions,
      tables,
    );
  }
}
