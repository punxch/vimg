import 'dart:typed_data';

import 'package:image/image.dart' as image;

import 'binary_file.dart';
import 'dib_palette.dart';
import 'frame_packet.dart';
import 'huffyuv.dart';
import 'metadata.dart';
import 'msrle.dart';
import 'msvideo1.dart';
import 'raw_video.dart';

typedef _Chunk = ({String id, int data, int end});
typedef _ColorMasks = ({int r, int g, int b});
typedef _Bitmap = ({
  int width,
  int height,
  int bits,
  bool topDown,
  _ColorMasks? masks,
});
typedef _Track = ({
  int index,
  VideoStream stream,
  double step,
  int scale,
  int rate,
  _Bitmap? bitmap,
  RawVideoFormat? raw,
  Uint8List? cinepakDescription,
  MsRleFormat? rle,
  MsVideo1Format? video1,
  _Chunk? huffFormat,
  _Chunk? nalFormat,
  List<int>? palette,
});

final class Avi {
  Avi(this.file);

  final BinaryFile file;

  String _tag(int offset) => String.fromCharCodes(file.read(offset, 4));
  int _u32(int offset) =>
      ByteData.sublistView(file.read(offset, 4)).getUint32(0, Endian.little);
  int _i32(int offset) =>
      ByteData.sublistView(file.read(offset, 4)).getInt32(0, Endian.little);
  int _u16(int offset) =>
      ByteData.sublistView(file.read(offset, 2)).getUint16(0, Endian.little);

  Iterable<_Chunk> _chunks(int start, int end) sync* {
    var offset = start;
    while (offset < end) {
      if (end - offset < 8)
        throw const FormatException('Truncated AVI chunk header');
      final id = _tag(offset);
      final size = _u32(offset + 4);
      final data = offset + 8;
      if (size > end - data) throw const FormatException('Truncated AVI chunk');
      yield (id: id, data: data, end: data + size);
      offset = data + size + (size & 1);
    }
  }

  bool _list(_Chunk chunk, String id) =>
      chunk.id == 'LIST' &&
      chunk.end - chunk.data >= 4 &&
      _tag(chunk.data) == id;

  late final _Chunk _root = _aviHeader();
  _Chunk _aviHeader() {
    final root = _chunks(0, file.length).firstOrNull;
    if (root == null ||
        root.id != 'RIFF' ||
        root.end - root.data < 4 ||
        _tag(root.data) != 'AVI ') {
      throw const FormatException('Missing AVI RIFF header');
    }
    return root;
  }

  late final ({List<_Track> tracks, double? duration}) _header = _readHeader();

  ({List<_Track> tracks, double? duration}) _readHeader() {
    final header = _chunks(
      _root.data + 4,
      _root.end,
    ).where((chunk) => _list(chunk, 'hdrl')).firstOrNull;
    if (header == null)
      throw const FormatException('Missing AVI stream headers');
    final tracks = <_Track>[];
    double? duration;
    var streamIndex = 0;
    for (final list in _chunks(header.data + 4, header.end)) {
      if (!_list(list, 'strl')) continue;
      final index = streamIndex++;
      final chunks = {
        for (final chunk in _chunks(list.data + 4, list.end)) chunk.id: chunk,
      };
      final stream = chunks['strh'];
      if (stream == null || stream.end - stream.data < 36) {
        throw const FormatException('Truncated AVI stream header');
      }
      final scale = _u32(stream.data + 20);
      final rate = _u32(stream.data + 24);
      if (scale == 0 || rate == 0) continue;
      final step = scale / rate;
      final length = _u32(stream.data + 32) * step;
      if (length > 0 && (duration == null || length > duration))
        duration = length;
      if (_tag(stream.data) != 'vids') continue;
      final format = chunks['strf'];
      if (format == null || format.end - format.data < 20) {
        throw const FormatException('Truncated AVI bitmap info');
      }
      final width = _i32(format.data + 4);
      final signedHeight = _i32(format.data + 8);
      final height = signedHeight.abs();
      final bits = _u16(format.data + 14);
      if (width <= 0 || height <= 0)
        throw const FormatException('Invalid AVI video dimensions');
      final tag = _tag(format.data + 16);
      final compression = tag.toUpperCase();
      final codec = switch (compression) {
        'MJPG' || 'JPEG' => 'mjpeg',
        'PNG ' || 'MPNG' => 'png',
        'H264' || 'X264' || 'AVC1' || 'AVC3' => 'h264',
        'HEVC' || 'H265' || 'HVC1' || 'HEV1' => 'hevc',
        'XVID' || 'DIVX' || 'DX50' || 'FMP4' => 'mpeg4',
        'FFV1' => 'ffv1',
        'HFYU' => 'huffyuv',
        'FFVH' => 'ffvhuff',
        'HYMT' => 'hymt',
        'CVID' => 'cinepak',
        'MSVC' || 'CRAM' || 'WHAM' => 'msvideo1',
        '\x01\x00\x00\x00' ||
        '\x02\x00\x00\x00' ||
        'MRLE' ||
        'RLE ' ||
        'RLE4' ||
        'RLE8' => 'msrle',
        '\x00\x00\x00\x00' || '\x03\x00\x00\x00' => 'rawvideo',
        _ when RawVideoFormat.recognizes(tag) => 'rawvideo',
        _ => 'unknown',
      };
      final bitfields = compression == '\x03\x00\x00\x00';
      final dib = bitfields || compression == '\x00\x00\x00\x00';
      final bitmap = dib
          ? _bitmap(format, width, signedHeight, bits, bitfields: bitfields)
          : null;
      final MsRleFormat? rle;
      if (codec == 'msrle') {
        final depth = switch (compression) {
          '\x01\x00\x00\x00' || 'RLE8' => 8,
          '\x02\x00\x00\x00' || 'RLE4' => 4,
          _ => bits,
        };
        if (depth != bits) {
          throw const FormatException(
            'AVI compression conflicts with bitmap depth',
          );
        }
        rle = MsRleFormat(width, height, bits, topDown: signedHeight < 0);
      } else {
        rle = null;
      }
      final video1 = codec == 'msvideo1'
          ? MsVideo1Format(width, height, bits)
          : null;
      tracks.add((
        index: index,
        step: step,
        scale: scale,
        rate: rate,
        stream: VideoStream(
          codec: codec,
          width: width,
          height: height,
          timeBase: timeBase(scale, rate),
          nominalFrameRate: rate / scale,
        ),
        bitmap: bitmap,
        raw: codec == 'rawvideo' && !dib
            ? RawVideoFormat(tag, width, height)
            : null,
        cinepakDescription: codec == 'cinepak'
            ? _cinepakDescription(width, height, bits)
            : null,
        rle: rle,
        video1: video1,
        huffFormat: isHuffYuvCodec(codec) ? format : null,
        nalFormat: codec == 'h264' || codec == 'hevc' ? format : null,
        palette:
            rle != null ||
                video1?.indexed == true ||
                (bitmap != null && bits <= 8) ||
                (codec == 'cinepak' && bits == 8)
            ? readDibPalette(file, format.data, format.end, bits)
            : null,
      ));
    }
    return (tracks: tracks, duration: duration);
  }

  VideoMetadata metadata() => VideoMetadata(
    _header.duration,
    _header.tracks.map((track) => track.stream).toList(),
  );

  bool get supportsBitmap => _header.tracks.firstOrNull?.bitmap != null;
  RawVideoFormat? get rawFormat => _header.tracks.firstOrNull?.raw;
  Uint8List? get cinepakDescription =>
      _header.tracks.firstOrNull?.cinepakDescription;
  MsRleFormat? get rleFormat => _header.tracks.firstOrNull?.rle;
  MsVideo1Format? get video1Format => _header.tracks.firstOrNull?.video1;

  Uint8List? nalPrivateData() {
    final format = _header.tracks.firstOrNull?.nalFormat;
    if (format == null) return null;
    var length = format.end - format.data;
    if (length <= 40) return null;
    final headerSize = _u32(format.data);
    // Some muxers report the alignment byte in the chunk length only.
    if (headerSize.isOdd && headerSize == length - 1) length = headerSize;
    if (length - 40 > 1024 * 1024) {
      throw const FormatException('Oversized AVI codec configuration');
    }
    return file.read(format.data + 40, length - 40);
  }

  HuffYuvDecoder? huffYuvDecoder() {
    final format = _header.tracks.firstOrNull?.huffFormat;
    return format == null
        ? null
        : readHuffYuvFormat(file, format.data, format.end);
  }

  bool isUncompressedRle(FramePacket packet) =>
      packet.size == rleFormat!.bitmapSize &&
      file.unsigned(packet.offset - 6, 2) == 0x6462; // 'db'

  _Bitmap? _bitmap(
    _Chunk format,
    int width,
    int height,
    int bits, {
    required bool bitfields,
  }) {
    final supported = bitfields ? const [16, 32] : const [1, 4, 8, 16, 24, 32];
    if (!supported.contains(bits)) return null;
    _ColorMasks? masks;
    if (bitfields) {
      final length = format.end - format.data;
      final header = _u32(format.data);
      if (header < 40 || header > length || length < 52) {
        throw const FormatException('Truncated AVI bitmap masks');
      }
      final r = _u32(format.data + 40);
      final g = _u32(format.data + 44);
      final b = _u32(format.data + 48);
      if (r & g != 0 ||
          r & b != 0 ||
          g & b != 0 ||
          (r | g | b) >> bits != 0 ||
          ![r, g, b].every(_contiguousMask)) {
        throw const FormatException('Invalid AVI bitmap masks');
      }
      masks = (r: r, g: g, b: b);
    } else if (bits == 16) {
      masks = (r: 0x7c00, g: 0x03e0, b: 0x001f);
    }
    return (
      width: width,
      height: height.abs(),
      bits: bits,
      topDown: height < 0,
      masks: masks,
    );
  }

  bool _contiguousMask(int mask) {
    final step = mask & -mask;
    return step != 0 && mask & (mask + step) == 0;
  }

  Uint8List _cinepakDescription(int width, int height, int bits) {
    if (width > 65535 || height > 65535) {
      throw const FormatException('Invalid Cinepak dimensions in AVI');
    }
    final description = Uint8List(78);
    ByteData.sublistView(description)
      ..setUint16(24, width)
      ..setUint16(26, height)
      ..setUint16(74, bits)
      ..setUint16(76, 65535);
    return description;
  }

  Iterable<FramePacket> packets({FrameVisitor? onSample}) sync* {
    final track = _header.tracks.firstOrNull;
    if (track == null) return;
    final packets = track.palette == null
        ? _readPackets(track)
        : _paletteIndex.packets;
    for (final packet in packets) {
      onSample?.call(packet, false);
      yield packet;
    }
  }

  late final _paletteIndex = _readPaletteIndex();

  // Store one palette per change and share it between unchanged samples.
  ({List<FramePacket> packets, List<({int offset, List<int> colors})> changes})
  _readPaletteIndex() {
    final changes = <({int offset, List<int> colors})>[];
    final packets = _readPackets(
      _header.tracks.first,
      onPalette: (offset, colors) =>
          changes.add((offset: offset, colors: colors)),
    ).toList();
    return (packets: packets, changes: changes);
  }

  bool get hasPalette => _header.tracks.firstOrNull?.palette != null;

  List<int>? paletteFor(FramePacket packet) {
    final initial = _header.tracks.firstOrNull?.palette;
    if (initial == null) return null;
    final changes = _paletteIndex.changes;
    var lo = 0, hi = changes.length;
    while (lo < hi) {
      final middle = (lo + hi) ~/ 2;
      if (changes[middle].offset <= packet.offset) {
        lo = middle + 1;
      } else {
        hi = middle;
      }
    }
    return lo == 0 ? initial : changes[lo - 1].colors;
  }

  Iterable<FramePacket> _readPackets(
    _Track track, {
    void Function(int offset, List<int> colors)? onPalette,
  }) sync* {
    var frame = 0;
    var palette = track.palette;
    final prefix = track.index.toString().padLeft(2, '0');
    final paletteId = palette == null ? null : '${prefix}pc';
    List<int>? updatedPalette;
    for (final riff in _chunks(0, file.length)) {
      if (riff.id != 'RIFF' ||
          riff.end - riff.data < 4 ||
          !const ['AVI ', 'AVIX'].contains(_tag(riff.data))) {
        continue;
      }
      for (final chunk in _chunks(riff.data + 4, riff.end)) {
        if (!_list(chunk, 'movi')) continue;
        for (final sample in _samples(chunk, prefix, paletteId, 0)) {
          if (sample.id == paletteId) {
            updatedPalette ??= List<int>.of(palette!);
            _updatePalette(sample, updatedPalette);
            continue;
          }
          final index = frame++;
          // AVI zero-length samples mark dropped frames.
          if (sample.end == sample.data) continue;
          if (updatedPalette != null) {
            palette = updatedPalette;
            onPalette!(sample.data, palette);
            updatedPalette = null;
          }
          yield (
            seconds: index * track.step,
            offset: sample.data,
            size: sample.end - sample.data,
            timestamp: frameTimestamp(
              index,
              track.scale,
              track.rate,
              duration: 1,
            ),
          );
        }
      }
    }
  }

  void _updatePalette(_Chunk chunk, List<int> colors) {
    final length = chunk.end - chunk.data;
    if (length < 4) throw const FormatException('Truncated AVI palette change');
    final header = file.read(chunk.data, 4);
    final first = header[0];
    final count = header[1] == 0 ? 256 : header[1];
    if (first + count > 256 || length < 4 + 4 * count) {
      throw const FormatException('Invalid AVI palette change');
    }
    final entries = ByteData.sublistView(file.read(chunk.data + 4, 4 * count));
    for (var i = 0; i < count; i++) {
      // PALETTEENTRY stores R, G, B, flags. RGBQUAD in strf uses B, G, R, reserved.
      colors[first + i] = entries.getUint32(4 * i) >> 8;
    }
  }

  Iterable<_Chunk> _samples(
    _Chunk list,
    String prefix,
    String? paletteId,
    int depth,
  ) sync* {
    if (depth > 8)
      throw const FormatException('Too many nested AVI record lists');
    for (final chunk in _chunks(list.data + 4, list.end)) {
      if (chunk.id == '${prefix}dc' ||
          chunk.id == '${prefix}db' ||
          chunk.id == paletteId) {
        yield chunk;
      } else if (_list(chunk, 'rec ')) {
        yield* _samples(chunk, prefix, paletteId, depth + 1);
      }
    }
  }

  image.Image decodeBitmap(Uint8List bytes, {List<int>? palette}) {
    final bitmap = _header.tracks.firstOrNull?.bitmap;
    if (bitmap == null) throw UnsupportedError('Unsupported AVI bitmap format');
    final (:width, :height, :bits, :topDown, :masks) = bitmap;
    final colors = palette ?? _header.tracks.first.palette;
    final channels = bits ~/ 8;
    final stride = ((width * bits + 31) ~/ 32) * 4;
    if (stride > bytes.length ~/ height)
      throw const FormatException('Truncated AVI bitmap frame');
    final frame = image.Image(width: width, height: height);
    final data = ByteData.sublistView(bytes);
    final indexMask = (1 << bits) - 1;
    for (var row = 0; row < height; row++) {
      var offset = (topDown ? row : height - row - 1) * stride;
      for (var col = 0; col < width; col++) {
        if (colors != null) {
          final bit = col * bits;
          final index = bytes[offset + (bit >> 3)] >> (8 - bits - (bit & 7));
          final color = colors[index & indexMask];
          frame.setPixelRgb(
            col,
            row,
            color >> 16,
            color >> 8 & 255,
            color & 255,
          );
        } else if (masks != null) {
          final value = bits == 16
              ? data.getUint16(offset, Endian.little)
              : data.getUint32(offset, Endian.little);
          frame.setPixelRgb(
            col,
            row,
            _expandMask(value, masks.r),
            _expandMask(value, masks.g),
            _expandMask(value, masks.b),
          );
          offset += channels;
        } else {
          frame.setPixelRgb(
            col,
            row,
            bytes[offset + 2],
            bytes[offset + 1],
            bytes[offset],
          );
          offset += channels;
        }
      }
    }
    return frame;
  }

  int _expandMask(int value, int mask) {
    final step = mask & -mask;
    final max = mask ~/ step;
    final component = (value & mask) ~/ step;
    return switch (max) {
      31 => component << 3 | component >> 2,
      63 => component << 2 | component >> 4,
      255 => component,
      _ => (component * 255 + max ~/ 2) ~/ max,
    };
  }
}
