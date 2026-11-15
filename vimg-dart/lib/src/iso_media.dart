import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as image;

import 'binary_file.dart';
import 'frame_packet.dart';
import 'metadata.dart';
import 'mpeg12/syntax.dart';

part 'iso_descriptors.dart';
part 'iso_fragments.dart';
part 'iso_frames.dart';

typedef MediaBox = ({String type, int start, int data, int end});

final class IsoMedia {
  IsoMedia(this.file);

  final BinaryFile file;
  late final MediaBox _movie =
      boxes(0, file.length).where((box) => box.type == 'moov').firstOrNull ??
      (throw const FormatException('Missing ISO media movie box'));
  late final _MovieFragments? _fragments = _readMovieFragments(this);

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
      yield (
        type: type,
        start: offset,
        data: offset + headerSize,
        end: offset + length,
      );
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

  MediaBox movie() => _movie;

  bool get hasOverlappingVideoFragments =>
      _fragments?.tracks[firstVideoTrack()]?.overlaps ?? false;

  MediaBox? firstVideoTrack({MediaBox? moov}) =>
      children(moov ?? movie()).where((box) {
        if (box.type != 'trak') return false;
        final handler = child(child(box, 'mdia'), 'hdlr');
        if (handler == null) return false;
        requireBytes(handler, 12);
        return tag(handler.data + 8) == 'vide';
      }).firstOrNull;

  /// Display orientation of the selected video track, composed with the movie
  /// matrix. Translation and scale do not change the capture orientation.
  VideoOrientation? videoOrientation() {
    final moov = movie();
    final track = child(firstVideoTrack(moov: moov), 'tkhd');
    final header = child(moov, 'mvhd');
    final local = _displayMatrix(track, narrow: 40, wide: 52);
    final global = _displayMatrix(header, narrow: 36, wide: 48);
    if (local == null && global == null) return null;
    double element(int row, int column) {
      if (local == null) return global![row * 3 + column];
      if (global == null) return local[row * 3 + column];
      return local[row * 3] * global[column] +
          local[row * 3 + 1] * global[3 + column] +
          local[row * 3 + 2] * global[6 + column];
    }

    final a = element(0, 0), b = element(0, 1);
    final c = element(1, 0), d = element(1, 1);
    final sx = math.sqrt(a * a + c * c), sy = math.sqrt(b * b + d * d);
    if (sx == 0 || sy == 0) return null;
    final angle = (math.atan2(b / sy, a / sx) * 180 / math.pi).round() % 360;
    // The sign of the other matrix axis distinguishes mirrors from rotations.
    return switch (angle) {
      0 => d < 0 ? (degrees: 0, horizontal: false, vertical: true) : null,
      90 => (degrees: 90, horizontal: c > 0, vertical: false),
      180 => (degrees: 0, horizontal: a < 0, vertical: d < 0),
      270 => (degrees: 270, horizontal: c < 0, vertical: false),
      _ => (degrees: angle, horizontal: false, vertical: false),
    };
  }

  List<double>? _displayMatrix(
    MediaBox? box, {
    required int narrow,
    required int wide,
  }) {
    if (box == null || box.data == box.end) return null;
    final offset = switch (file.unsigned(box.data, 1)) {
      0 => narrow,
      1 => wide,
      _ => box.end - box.data,
    };
    if (box.end - box.data < offset + 36) return null;
    final data = ByteData.sublistView(file.read(box.data + offset, 36));
    return [
      for (var i = 0; i < 9; i++)
        data.getInt32(i * 4) / (1 << (i % 3 == 2 ? 30 : 16)),
    ];
  }

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
          final stream = _stream(box, media, mediaTiming?.scale);
          if (stream != null) streams.add(stream);
        case 'udta':
          streams.addAll(_coverStreams(child(box, 'meta')));
        case 'meta':
          streams.addAll(_coverStreams(box));
      }
    }
    return VideoMetadata(
      _fragments?.duration ??
          (ticks == null || ticks == 0
              ? longestTrack
              : ticks / movieTiming!.scale),
      streams,
    );
  }

  MediaBox? sampleTable(MediaBox? media) => child(child(media, 'minf'), 'stbl');

  Iterable<MediaBox> sampleDescriptions(MediaBox? table) sync* {
    final descriptions = child(table, 'stsd');
    if (descriptions == null) return;
    requireBytes(descriptions, 8);
    final count = file.unsigned(descriptions.data + 4, 4);
    final entries = children(descriptions, skip: 8).iterator;
    for (var i = 0; i < count; i++) {
      if (!entries.moveNext()) {
        throw const FormatException('Incomplete ISO media sample descriptions');
      }
      yield entries.current;
    }
  }

  MediaBox? sampleDescription(MediaBox? table) =>
      sampleDescriptions(table).firstOrNull;

  VideoStream? _stream(MediaBox track, MediaBox? media, int? scale) {
    if (scale == null) return null;
    final table = sampleTable(media);
    if (table == null) return null;
    final chunks = _Table.optional(this, table, 'stsc', 12);
    final index = chunks != null && chunks.count > 0
        ? chunks.value(0, 8)
        : _fragments?.tracks[track]?.runs.firstOrNull?.defaults.description ??
              1;
    final entries = sampleDescriptions(table);
    final entry = index > 0 ? entries.skip(index - 1).firstOrNull : null;
    if (entry == null) {
      if (index == 1 && entries.isEmpty) return null;
      throw const FormatException('Invalid ISO media sample description index');
    }
    requireBytes(entry, 28);
    return VideoStream(
      codec: videoCodec(entry),
      width: file.unsigned(entry.data + 24, 2),
      height: file.unsigned(entry.data + 26, 2),
      timeBase: '1/$scale',
    );
  }

  String videoCodec(MediaBox entry) => switch (entry.type) {
    'FFV1' || 'ffv1' => 'ffv1',
    'avc1' || 'avc2' || 'avc3' || 'avc4' || 'dva1' || 'dvav' => 'h264',
    'hvc1' || 'hev1' || 'dvhe' || 'dvh1' => 'hevc',
    'vvc1' || 'vvi1' => 'vvc',
    'av01' => 'av1',
    'vp08' => 'vp8',
    'vp09' => 'vp9',
    'mp4v' => _visualDescriptor(entry)?.codec ?? 'mpeg4',
    'm1v ' || 'm1v1' || 'mpeg' || 'mp1v' => 'mpeg1video',
    'm2v1' || 'mp2v' || 'AVmp' => 'mpeg2video',
    _ when _mpeg2QuickTimeTags.hasMatch(entry.type) => 'mpeg2video',
    'jpeg' || 'mjpa' || 'mjpb' || 'mjpg' => 'mjpeg',
    'ap4h' || 'ap4x' || 'apch' || 'apcn' || 'apcs' || 'apco' => 'prores',
    'aprn' || 'aprh' => 'prores_raw',
    'png ' => 'png',
    'rle ' => 'qtrle',
    'rpza' => 'rpza',
    'smc ' => 'smc',
    'cvid' => 'cinepak',
    'raw ' ||
    'yuv2' ||
    '2vuy' ||
    '2vuY' ||
    'v216' ||
    'v308' ||
    'v408' ||
    'v410' => 'rawvideo',
    'v210' => 'v210',
    _ => 'unknown',
  };

  Uint8List? mpegVideoConfiguration({MediaBox? description}) {
    final entry =
        description ??
        sampleDescription(sampleTable(child(firstVideoTrack(), 'mdia')));
    if (entry == null) return null;
    final global = visualExtension(entry, 'glbl');
    final extent =
        _visualDescriptor(entry)?.specific ??
        (global == null ? null : (data: global.data, end: global.end));
    if (extent == null || extent.data == extent.end) return null;
    final length = extent.end - extent.data;
    if (length > 1024 * 1024) {
      throw const FormatException('Oversized MPEG video configuration');
    }
    final bytes = file.read(extent.data, length);
    // Some QuickTime entries carry vendor metadata in the global box.
    return mpegStartCodes(bytes).any((unit) => unit.code == 0xb3)
        ? bytes
        : null;
  }

  Iterable<MediaBox> coverData(MediaBox? meta) sync* {
    if (meta == null) return;
    for (final list in children(
      meta,
      skip: 4,
    ).where((box) => box.type == 'ilst')) {
      for (final cover in children(list).where((box) => box.type == 'covr')) {
        for (final data in children(cover).where((box) => box.type == 'data')) {
          requireBytes(data, 8);
          final kind = file.unsigned(data.data + 1, 3);
          if (kind == 13 || kind == 14) yield data;
        }
      }
    }
  }

  Iterable<VideoStream> _coverStreams(MediaBox? meta) sync* {
    for (final data in coverData(meta)) {
      final length = data.end - data.data - 8;
      if (length > 32 * 1024 * 1024) continue;
      final bytes = file.read(data.data + 8, length);
      final kind = file.unsigned(data.data + 1, 3);
      final decoder = kind == 13 ? image.JpegDecoder() : image.PngDecoder();
      final info = decoder.startDecode(bytes);
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

// QuickTime tags for MPEG-2 HDV, IMX and XDCAM.
final _mpeg2QuickTimeTags = RegExp(
  r'^(hdv[1-9a]|mx[345][np]|xd5[1459a-f]|xdv[1-9a-f]|xdh[d2])$',
);
