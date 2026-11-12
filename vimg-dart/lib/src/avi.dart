import 'dart:typed_data';

import 'package:image/image.dart' as image;

import 'binary_file.dart';
import 'frame_packet.dart';
import 'metadata.dart';

typedef _Chunk = ({String id, int data, int end});
typedef _Bitmap = ({int width, int height, int bits, bool topDown});
typedef _Track = ({
  int index,
  VideoStream stream,
  double step,
  int scale,
  int rate,
  _Bitmap? bitmap,
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
      final compression = _tag(format.data + 16).toUpperCase();
      final codec = switch (compression) {
        'MJPG' || 'JPEG' => 'mjpeg',
        'PNG ' || 'MPNG' => 'png',
        'H264' || 'X264' || 'AVC1' => 'h264',
        'HEVC' || 'H265' => 'hevc',
        'XVID' || 'DIVX' || 'DX50' || 'FMP4' => 'mpeg4',
        'FFV1' => 'ffv1',
        '\x00\x00\x00\x00' => 'rawvideo',
        _ => 'unknown',
      };
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
        bitmap: codec == 'rawvideo' && (bits == 24 || bits == 32)
            ? (
                width: width,
                height: height,
                bits: bits,
                topDown: signedHeight < 0,
              )
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

  Iterable<FramePacket> packets() sync* {
    final track = _header.tracks.firstOrNull;
    if (track == null) return;
    var frame = 0;
    for (final riff in _chunks(0, file.length)) {
      if (riff.id != 'RIFF' ||
          riff.end - riff.data < 4 ||
          !const ['AVI ', 'AVIX'].contains(_tag(riff.data))) {
        continue;
      }
      for (final chunk in _chunks(riff.data + 4, riff.end)) {
        if (!_list(chunk, 'movi')) continue;
        for (final sample in _samples(chunk, track.index, 0)) {
          final index = frame++;
          // AVI zero-length samples mark dropped frames.
          if (sample.end == sample.data) continue;
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

  Iterable<_Chunk> _samples(_Chunk list, int track, int depth) sync* {
    if (depth > 8)
      throw const FormatException('Too many nested AVI record lists');
    final prefix = track.toString().padLeft(2, '0');
    for (final chunk in _chunks(list.data + 4, list.end)) {
      if (chunk.id == '${prefix}dc' || chunk.id == '${prefix}db') {
        yield chunk;
      } else if (_list(chunk, 'rec ')) {
        yield* _samples(chunk, track, depth + 1);
      }
    }
  }

  image.Image decodeBitmap(Uint8List bytes) {
    final bitmap = _header.tracks.firstOrNull?.bitmap;
    if (bitmap == null) throw UnsupportedError('Unsupported AVI bitmap format');
    final (:width, :height, :bits, :topDown) = bitmap;
    final channels = bits ~/ 8;
    final stride = (width * channels + 3) & ~3;
    if (stride > bytes.length ~/ height)
      throw const FormatException('Truncated AVI bitmap frame');
    final frame = image.Image(width: width, height: height);
    for (var row = 0; row < height; row++) {
      var offset = (topDown ? row : height - row - 1) * stride;
      for (var col = 0; col < width; col++) {
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
    return frame;
  }
}
