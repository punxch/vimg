import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as image;

import 'binary_file.dart';
import 'frame_packet.dart';
import 'metadata.dart';
import 'raw_video.dart';

part 'matroska_compression.dart';

const _ebml = 0x1a45dfa3;
const _segment = 0x18538067;
const matroskaCluster = 0x1f43b675;

const _codecs = {
  'V_AV1': 'av1',
  'V_MPEG4/ISO/AVC': 'h264',
  'V_MPEGH/ISO/HEVC': 'hevc',
  'V_MPEGI/ISO/VVC': 'vvc',
  'V_MPEG4/ISO/ASP': 'mpeg4',
  'V_MPEG4/ISO/SP': 'mpeg4',
  'V_MPEG2': 'mpeg2video',
  'V_MPEG1': 'mpeg1video',
  'V_VP8': 'vp8',
  'V_VP9': 'vp9',
  'V_MJPEG': 'mjpeg',
  'V_PNG': 'png',
  'V_FFV1': 'ffv1',
  'V_PRORES': 'prores',
  'V_THEORA': 'theora',
  'V_UNCOMPRESSED': 'rawvideo',
};

typedef EbmlElement = ({int id, int data, int end, bool unknownSize});

final class Matroska {
  Matroska(this.file);

  final BinaryFile file;

  late final firstVideoTrack = segmentElements()
      .where((element) => element.id == 0x1654ae6b)
      .expand(videoTracks)
      .firstOrNull;
  final _encodings = <int, List<_ContentCompression>>{};
  final _privateData = <int, Uint8List>{};
  late final _frameEncodings = firstVideoTrack == null
      ? const <_ContentCompression>[]
      : _contentEncodings(
          firstVideoTrack!,
        ).where((entry) => entry.scope & 1 != 0).toList();

  bool get hasEncodedFrames => _frameEncodings.isNotEmpty;

  Uint8List readFrame(FramePacket packet) {
    if (packet.size < 0 || packet.size > _maxFramePayload) {
      throw const FormatException('Invalid video frame size');
    }
    final bytes = _restoreContent(
      file.read(packet.offset, packet.size),
      _frameEncodings,
      _maxFramePayload,
    );
    if (bytes.isEmpty) {
      throw const FormatException('Invalid video frame size');
    }
    return bytes;
  }

  Uint8List readFramePrefix(FramePacket packet, int count) {
    if (!hasEncodedFrames) {
      return file.read(packet.offset, math.min(packet.size, count));
    }
    if (_frameEncodings.length == 1 && _frameEncodings.single.algorithm == 3) {
      final prefix = _frameEncodings.single.settings;
      if (prefix.length >= count)
        return Uint8List.sublistView(prefix, 0, count);
      final body = file.read(
        packet.offset,
        math.min(packet.size, count - prefix.length),
      );
      return _prepend(prefix, body, count);
    }
    final bytes = readFrame(packet);
    return Uint8List.sublistView(bytes, 0, math.min(bytes.length, count));
  }

  Uint8List? codecPrivate(Map<int, EbmlElement> track) {
    final field = track[0x63a2];
    if (field == null) return null;
    return _privateData.putIfAbsent(field.data, () {
      const limit = 1024 * 1024;
      final count = field.end - field.data;
      if (count > limit) {
        throw const FormatException('Oversized Matroska codec private data');
      }
      final encodings = _contentEncodings(
        track,
      ).where((entry) => entry.scope & 2 != 0);
      return _restoreContent(file.read(field.data, count), encodings, limit);
    });
  }

  List<_ContentCompression> _contentEncodings(Map<int, EbmlElement> track) {
    final parent = track[0x6d80];
    if (parent == null) return const [];
    return _encodings.putIfAbsent(
      parent.data,
      () => _readContentEncodings(this, parent),
    );
  }

  ({int value, int width}) vint(int offset, int end, {bool id = false}) {
    if (offset >= end) throw const FormatException('Missing EBML integer');
    final first = file.unsigned(offset, 1);
    if (first == 0) throw const FormatException('Invalid EBML integer');
    final width = 9 - first.bitLength;
    if ((id && width > 4) || offset + width > end) {
      throw const FormatException('Invalid EBML integer width');
    }
    final marker = 1 << (8 - width);
    var value = id ? first : first ^ marker;
    for (final byte in file.read(offset + 1, width - 1)) {
      value = (value << 8) | byte;
    }
    return (value: value, width: width);
  }

  EbmlElement element(int offset, int end) {
    final id = vint(offset, end, id: true);
    final size = vint(offset + id.width, end);
    final data = offset + id.width + size.width;
    final unknownSize = size.value == (1 << (7 * size.width)) - 1;
    if (!unknownSize && size.value > end - data) {
      throw const FormatException('EBML element exceeds its parent');
    }
    return (
      id: id.value,
      data: data,
      end: unknownSize ? end : data + size.value,
      unknownSize: unknownSize,
    );
  }

  Iterable<EbmlElement> elements(int offset, int end) sync* {
    while (offset < end) {
      final next = element(offset, end);
      yield next;
      offset = next.end;
    }
  }

  Iterable<EbmlElement> segmentElements() sync* {
    final header = element(0, file.length);
    if (header.id != _ebml || header.unknownSize) {
      throw const FormatException('Invalid Matroska header');
    }
    final type = text(fields(header)[0x4282]);
    if (type != 'matroska' && type != 'webm') {
      throw FormatException('Unsupported EBML document type: $type');
    }
    for (final root in elements(header.end, file.length)) {
      if (root.id != _segment) continue;
      var offset = root.data;
      while (offset < root.end) {
        var child = element(offset, root.end);
        if (child.id == matroskaCluster && child.unknownSize) {
          // A live muxer may omit the cluster size. The next Segment-level
          // element closes it.
          var boundary = child.data;
          while (boundary < root.end) {
            final next = element(boundary, root.end);
            if (_segmentIds.contains(next.id)) break;
            if (next.unknownSize) {
              throw const FormatException(
                'Unknown size within Matroska cluster',
              );
            }
            boundary = next.end;
          }
          child = (
            id: child.id,
            data: child.data,
            end: boundary,
            unknownSize: true,
          );
        }
        yield child;
        offset = child.end;
      }
      return;
    }
    throw const FormatException('Missing Matroska segment');
  }

  static const _segmentIds = {
    matroskaCluster,
    0x114d9b74,
    0x1549a966,
    0x1654ae6b,
    0x1c53bb6b,
    0x1941a469,
    0x1043a770,
    0x1254c367,
  };

  Map<int, EbmlElement> fields(EbmlElement parent) => {
    for (final child in elements(parent.data, parent.end)) child.id: child,
  };

  int? number(EbmlElement? field) =>
      field == null ? null : file.unsigned(field.data, field.end - field.data);

  String? text(EbmlElement? field) {
    if (field == null) return null;
    final length = field.end - field.data;
    if (length > 4096) throw const FormatException('Oversized EBML string');
    return utf8
        .decode(file.read(field.data, length), allowMalformed: true)
        .split('\x00')
        .first;
  }

  double? floating(EbmlElement? field) {
    if (field == null) return null;
    final length = field.end - field.data;
    final bytes = ByteData.sublistView(
      file.read(field.data, length.clamp(0, 8)),
    );
    return switch (length) {
      4 => bytes.getFloat32(0),
      8 => bytes.getFloat64(0),
      _ => throw const FormatException('Invalid EBML float width'),
    };
  }

  VideoMetadata metadata() {
    var scale = 1000000;
    double? durationTicks;
    final tracks =
        <({String codec, int width, int height, int? frameDuration})>[];
    final attachments = <VideoStream>[];
    for (final child in segmentElements()) {
      switch (child.id) {
        case 0x1549a966:
          final info = fields(child);
          scale = number(info[0x2ad7b1]) ?? scale;
          if (scale <= 0)
            throw const FormatException('Invalid Matroska timestamp scale');
          durationTicks = floating(info[0x4489]);
        case 0x1654ae6b:
          for (final track in videoTracks(child)) {
            final video = fields(track[0xe0]!);
            tracks.add((
              codec: trackCodec(track),
              width: number(video[0xb0]) ?? 0,
              height: number(video[0xba]) ?? 0,
              frameDuration: number(track[0x23e383]),
            ));
          }
        case 0x1941a469:
          for (final entry in pictureAttachments(child)) {
            final attached = _attachment(entry);
            if (attached != null) attachments.add(attached);
          }
      }
    }
    final duration = durationTicks == null ? null : durationTicks * scale / 1e9;
    final base = timeBase(scale, 1000000000);
    return VideoMetadata(
      duration != null && duration.isFinite && duration >= 0 ? duration : null,
      [
        for (final track in tracks)
          VideoStream(
            codec: track.codec,
            width: track.width,
            height: track.height,
            timeBase: base,
            nominalFrameRate: _matroskaFrameRate(track.frameDuration),
          ),
        ...attachments,
      ],
    );
  }

  Iterable<Map<int, EbmlElement>> videoTracks(EbmlElement tracks) sync* {
    for (final entry in elements(tracks.data, tracks.end)) {
      if (entry.id != 0xae) continue;
      final track = fields(entry);
      if (number(track[0x83]) == 1 && track.containsKey(0xe0)) yield track;
    }
  }

  ({VideoCrop? crop, VideoOrientation? orientation, double? sampleAspect})
  videoPresentation() {
    final track = firstVideoTrack;
    if (track == null)
      return (crop: null, orientation: null, sampleAspect: null);
    final video = fields(track[0xe0]!);
    final crop = (
      left: number(video[0x54cc]) ?? 0,
      top: number(video[0x54bb]) ?? 0,
      right: number(video[0x54dd]) ?? 0,
      bottom: number(video[0x54aa]) ?? 0,
    );
    final width = number(video[0xb0]) ?? 0, height = number(video[0xba]) ?? 0;
    final hasCrop = crop != (left: 0, top: 0, right: 0, bottom: 0);
    if (hasCrop &&
        (crop.left < 0 ||
            crop.right < 0 ||
            crop.top < 0 ||
            crop.bottom < 0 ||
            crop.left >= width ||
            crop.right >= width - crop.left ||
            crop.top >= height ||
            crop.bottom >= height - crop.top)) {
      throw const FormatException('Invalid Matroska video crop');
    }
    final croppedWidth = width - crop.left - crop.right;
    final croppedHeight = height - crop.top - crop.bottom;

    final unit = number(video[0x54b2]) ?? 0;
    final displayWidth = number(video[0x54b0]);
    final displayHeight = number(video[0x54ba]);
    double? aspect;
    if (unit >= 0 &&
        unit <= 3 &&
        (displayWidth != null || displayHeight != null) &&
        croppedWidth > 0 &&
        croppedHeight > 0) {
      final w = displayWidth ?? (unit == 0 ? croppedWidth : 0);
      final h = displayHeight ?? (unit == 0 ? croppedHeight : 0);
      if (w > 0 && h > 0) aspect = (w / h) / (croppedWidth / croppedHeight);
    }
    return (
      crop: hasCrop ? crop : null,
      orientation: _flatOrientation(video[0x7670]),
      sampleAspect: aspect,
    );
  }

  VideoOrientation? _flatOrientation(EbmlElement? box) {
    if (box == null) return null;
    final projection = fields(box);
    if ((number(projection[0x7671]) ?? 0) != 0) return null;
    final yaw = floating(projection[0x7673]) ?? 0;
    final pitch = floating(projection[0x7674]) ?? 0;
    final roll = floating(projection[0x7675]) ?? 0;
    if (pitch != 0 ||
        (yaw != 0 && yaw.abs() != 180) ||
        !roll.isFinite ||
        roll.abs() > 180)
      return null;
    final mirror = yaw != 0;
    // Matroska applies yaw before counterclockwise roll. Moving the mirror
    // after the rotation reverses the angle when both are present.
    final angle = (mirror ? roll : -roll).round() % 360;
    return angle == 0 && !mirror
        ? null
        : (degrees: angle, horizontal: mirror, vertical: false);
  }

  String trackCodec(Map<int, EbmlElement> track) {
    final codec = text(track[0x86]);
    final config = codec == 'V_PRORES' || codec == 'V_MS/VFW/FOURCC'
        ? codecPrivate(track)
        : null;
    if (codec == 'V_PRORES' && config != null && config.length == 4) {
      final tag = ByteData.sublistView(config).getUint32(0);
      if (tag == 0x6170726e || tag == 0x61707268) return 'prores_raw';
    }
    if (codec == 'V_MS/VFW/FOURCC' && config != null && config.length >= 20) {
      final tag = ascii.decode(
        Uint8List.sublistView(config, 16, 20),
        allowInvalid: true,
      );
      return switch (tag.toUpperCase()) {
        'MJPG' || 'JPEG' => 'mjpeg',
        'MPNG' || 'PNG ' => 'png',
        'H264' || 'X264' || 'AVC1' => 'h264',
        'HEVC' || 'H265' => 'hevc',
        'XVID' || 'DIVX' || 'DX50' || 'FMP4' || 'MP4V' => 'mpeg4',
        'VP80' || 'VP08' => 'vp8',
        'VP90' || 'VP09' => 'vp9',
        'FFV1' => 'ffv1',
        'HFYU' => 'huffyuv',
        'FFVH' => 'ffvhuff',
        'HYMT' => 'hymt',
        'MSVC' || 'CRAM' || 'WHAM' => 'msvideo1',
        _ when RawVideoFormat.recognizes(tag) => 'rawvideo',
        _ => 'unknown',
      };
    }
    return _codecs[codec] ?? 'unknown';
  }

  Iterable<Map<int, EbmlElement>> pictureAttachments(EbmlElement parent) sync* {
    for (final entry in elements(parent.data, parent.end)) {
      if (entry.id != 0x61a7) continue;
      final attachment = fields(entry);
      if (text(attachment[0x4660])?.startsWith('image/') == true &&
          attachment.containsKey(0x465c)) {
        yield attachment;
      }
    }
  }

  VideoStream? _attachment(Map<int, EbmlElement> entry) {
    final mime = text(entry[0x4660]);
    final data = entry[0x465c];
    final codec = switch (mime) {
      'image/jpeg' => 'mjpeg',
      'image/png' => 'png',
      'image/bmp' => 'bmp',
      'image/gif' => 'gif',
      'image/tiff' => 'tiff',
      'image/webp' => 'webp',
      _ => null,
    };
    if (data == null ||
        codec == null ||
        data.end - data.data > 32 * 1024 * 1024) {
      return null;
    }
    final bytes = file.read(data.data, data.end - data.data);
    final info = image.findDecoderForData(bytes)?.startDecode(bytes);
    if (info == null) return null;
    return VideoStream(
      codec: codec,
      width: info.width,
      height: info.height,
      timeBase: '1/90000',
      attached: true,
    );
  }
}

double? _matroskaFrameRate(int? duration) {
  if (duration == null || duration <= 0) return null;
  // DefaultDuration stores whole nanoseconds. Recover common broadcast rates
  // when the only difference is that timestamp precision.
  final rate = 1e9 / duration;
  final integer = rate.round();
  if (integer > 0 && (duration - 1e9 / integer).abs() < 1) {
    return integer.toDouble();
  }
  for (final numerator in [24000, 30000, 48000, 60000, 96000, 120000]) {
    if ((duration - 1001e9 / numerator).abs() < 1) return numerator / 1001;
  }
  return rate;
}
