import 'package:image/image.dart' as image;

import 'binary_file.dart';
import 'metadata.dart';

typedef MediaBox = ({String type, int data, int end});

final class IsoMedia {
  IsoMedia(this.file);

  final BinaryFile file;

  String tag(int offset) => String.fromCharCodes(file.read(offset, 4));

  Iterable<MediaBox> boxes(int offset, int end) sync* {
    while (offset < end) {
      if (end - offset < 8) throw const FormatException('Truncated box header');
      final size = file.unsigned(offset, 4);
      final type = tag(offset + 4);
      var headerSize = size == 1 ? 16 : 8;
      if (type == 'uuid') headerSize += 16;
      if (end - offset < headerSize) {
        throw const FormatException('Truncated extended box header');
      }
      final length = switch (size) {
        0 => end - offset,
        1 => file.unsigned(offset + 8, 8),
        _ => size,
      };
      if (length < headerSize || length > end - offset) {
        throw FormatException('Invalid size for box $type');
      }
      yield (type: type, data: offset + headerSize, end: offset + length);
      offset += length;
    }
  }

  Iterable<MediaBox> children(MediaBox box, {int skip = 0}) {
    requireBytes(box, skip);
    return boxes(box.data + skip, box.end);
  }

  MediaBox? child(MediaBox? parent, String type) => parent == null
      ? null
      : children(parent).where((box) => box.type == type).firstOrNull;

  void requireBytes(MediaBox box, int count) {
    if (box.end - box.data < count) {
      throw FormatException('Truncated ${box.type} box');
    }
  }

  ({int scale, int? duration})? timing(MediaBox? box) {
    if (box == null) return null;
    requireBytes(box, 4);
    final version = file.unsigned(box.data, 1);
    if (version > 1)
      throw FormatException('Unsupported ${box.type} version $version');
    final wide = version == 1;
    final offset = wide ? 20 : 12;
    requireBytes(box, wide ? 32 : 20);
    final scale = file.unsigned(box.data + offset, 4);
    if (scale == 0) return null;
    final duration = file.unsigned(box.data + offset + 4, wide ? 8 : 4);
    return (
      scale: scale,
      duration: duration < 0 || (!wide && duration == 0xffffffff)
          ? null
          : duration,
    );
  }

  MediaBox movie() =>
      boxes(0, file.length).where((box) => box.type == 'moov').firstOrNull ??
      (throw const FormatException('Missing ISO media movie box'));

  VideoMetadata metadata() {
    final moov = movie();
    final movieTiming = timing(child(moov, 'mvhd'));
    final ticks = movieTiming?.duration;
    final streams = <VideoStream>[];
    double? longestTrack;
    for (final box in children(moov)) {
      switch (box.type) {
        case 'trak':
          final media = child(box, 'mdia');
          final handler = child(media, 'hdlr');
          final mediaTiming = timing(child(media, 'mdhd'));
          if (mediaTiming case (:final scale, duration: final duration?)) {
            final seconds = duration / scale;
            if (longestTrack == null || seconds > longestTrack) {
              longestTrack = seconds;
            }
          }
          if (handler == null) continue;
          requireBytes(handler, 12);
          if (tag(handler.data + 8) != 'vide') continue;
          final stream = _stream(media, mediaTiming?.scale);
          if (stream != null) streams.add(stream);
        case 'udta':
          streams.addAll(_covers(child(box, 'meta')));
        case 'meta':
          streams.addAll(_covers(box));
      }
    }
    return VideoMetadata(
      ticks == null || ticks == 0 ? longestTrack : ticks / movieTiming!.scale,
      streams,
    );
  }

  MediaBox? sampleTable(MediaBox? media) => child(child(media, 'minf'), 'stbl');

  MediaBox? sampleDescription(MediaBox? table) {
    final descriptions = child(table, 'stsd');
    if (descriptions == null) return null;
    requireBytes(descriptions, 8);
    if (file.unsigned(descriptions.data + 4, 4) == 0) return null;
    return children(descriptions, skip: 8).firstOrNull;
  }

  VideoStream? _stream(MediaBox? media, int? scale) {
    final entry = sampleDescription(sampleTable(media));
    if (entry == null || scale == null) return null;
    requireBytes(entry, 28);
    final codec = switch (entry.type) {
      'avc1' || 'avc2' || 'avc3' || 'avc4' || 'dva1' || 'dvav' => 'h264',
      'hvc1' || 'hev1' || 'dvhe' || 'dvh1' => 'hevc',
      'vvc1' || 'vvi1' => 'vvc',
      'av01' => 'av1',
      'vp08' => 'vp8',
      'vp09' => 'vp9',
      'mp4v' => 'mpeg4',
      'jpeg' || 'mjpa' || 'mjpb' || 'mjpg' => 'mjpeg',
      'ap4h' || 'ap4x' || 'apch' || 'apcn' || 'apcs' || 'apco' => 'prores',
      'png ' => 'png',
      'raw ' || 'yuv2' || '2vuy' => 'rawvideo',
      _ => 'unknown',
    };
    return VideoStream(
      codec: codec,
      width: file.unsigned(entry.data + 24, 2),
      height: file.unsigned(entry.data + 26, 2),
      timeBase: '1/$scale',
    );
  }

  Iterable<VideoStream> _covers(MediaBox? meta) sync* {
    if (meta == null) return;
    for (final list in children(
      meta,
      skip: 4,
    ).where((box) => box.type == 'ilst')) {
      for (final cover in children(list).where((box) => box.type == 'covr')) {
        for (final data in children(cover).where((box) => box.type == 'data')) {
          requireBytes(data, 8);
          final length = data.end - data.data - 8;
          if (length > 32 * 1024 * 1024) continue;
          final bytes = file.read(data.data + 8, length);
          final kind = file.unsigned(data.data + 1, 3);
          final decoder = switch (kind) {
            13 => image.JpegDecoder(),
            14 => image.PngDecoder(),
            _ => null,
          };
          final info = decoder?.startDecode(bytes);
          if (info == null) continue;
          yield VideoStream(
            codec: kind == 13 ? 'mjpeg' : 'png',
            width: info.width,
            height: info.height,
            timeBase: '1/90000',
            attached: true,
          );
        }
      }
    }
  }
}
