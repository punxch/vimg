import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;

import 'avi.dart';
import 'binary_file.dart';
import 'frame_packet.dart';
import 'h264/access_unit.dart';
import 'video_configuration.dart';
import 'h264/idr_picture.dart';
import 'iso_frames.dart';
import 'iso_media.dart';
import 'matroska.dart';
import 'matroska_frames.dart';
import 'metadata.dart';

final class Video {
  Video(String path) : _input = File(path).openSync() {
    try {
      file = BinaryFile(_input);
      final signature = file.unsigned(0, 4);
      if (signature == 0x1a45dfa3) {
        _matroska = Matroska(file);
      } else if (signature == 0x52494646) {
        _avi = Avi(file);
      } else {
        _iso = IsoMedia(file);
      }
    } catch (_) {
      _input.closeSync();
      rethrow;
    }
  }

  final RandomAccessFile _input;
  late final BinaryFile file;
  Matroska? _matroska;
  IsoMedia? _iso;
  Avi? _avi;

  late final VideoMetadata metadata =
      _matroska?.metadata() ?? _avi?.metadata() ?? _iso!.metadata();

  String get codec =>
      metadata.streams.where((stream) => !stream.attached).firstOrNull?.codec ??
      (throw const FormatException('No video stream'));

  void close() => _input.closeSync();

  late final Uint8List _avcConfig = _openH264();
  late final H264IdrDecoder _h264 = H264IdrDecoder(
    AvcConfiguration(_avcConfig),
  );
  late final _H264Timeline _h264Timeline = _indexH264();

  Uint8List _openH264() {
    final matroska = _matroska;
    final iso = _iso;
    final config = matroska != null
        ? matroskaVideoConfiguration(matroska, 'h264')
        : (iso != null ? isoVideoConfiguration(iso, 'h264') : null);
    if (config == null)
      throw UnsupportedError(
        'H.264 requires a Matroska or MP4 AVC configuration',
      );
    return config;
  }

  Iterable<FramePacket> packets({bool preview = false}) {
    if (codec == 'h264') {
      return preview ? _h264Keyframes() : _h264Timeline.presentation;
    }
    final keyframes = preview && codec == 'vp8';
    final avi = _avi;
    final bitmap = codec == 'rawvideo' && avi?.supportsBitmap == true;
    if (codec != 'mjpeg' && codec != 'png' && !keyframes && !bitmap) {
      throw UnsupportedError('Pure Dart decoding for $codec is unavailable');
    }
    if (avi != null) return avi.packets();
    return _containerPackets(keyframes);
  }

  Iterable<FramePacket> _containerPackets(
    bool keyframes, {
    FrameVisitor? onSample,
  }) {
    final matroska = _matroska;
    return matroska == null
        ? isoFrames(_iso!, keyframes: keyframes, onSample: onSample)
        : matroskaFrames(matroska, keyframes: keyframes, onSample: onSample);
  }

  bool _isIdr(AvcConfiguration configuration, FramePacket packet) =>
      configuration.containsIdr(packet.offset, packet.size, file.unsigned);

  Iterable<FramePacket> _h264Keyframes() {
    final configuration = _h264.configuration;
    return _containerPackets(
      true,
    ).where((packet) => _isIdr(configuration, packet));
  }

  _H264Timeline _indexH264() {
    final configuration = _h264.configuration;
    final decodeOrder = <FramePacket>[];
    final index = <FramePacket, int>{};
    final gopStart = <int>[];
    var start = -1;
    final presentation = _containerPackets(
      false,
      onSample: (packet, sync) {
        final position = decodeOrder.length;
        if (sync && _isIdr(configuration, packet)) start = position;
        index[packet] = position;
        decodeOrder.add(packet);
        gopStart.add(start);
      },
    ).toList();
    presentation.sort((a, b) {
      final byTime = a.seconds.compareTo(b.seconds);
      return byTime == 0 ? index[a]!.compareTo(index[b]!) : byTime;
    });
    return (
      decodeOrder: decodeOrder,
      presentation: presentation,
      index: index,
      gopStart: gopStart,
    );
  }

  Iterable<({FramePacket packet, image.Image frame})> decodeSelected(
    Iterable<FramePacket> selected,
  ) sync* {
    if (codec != 'h264') {
      for (final packet in selected) {
        yield (packet: packet, frame: decode(packet));
      }
      return;
    }

    final timeline = _h264Timeline;
    final targets = {
      for (final packet in selected)
        timeline.index[packet] ??
            (throw const FormatException('Unknown H.264 video packet')),
    }.toList()..sort();
    H264StreamDecoder? decoder;
    var group = -1;
    var next = 0;
    for (final target in targets) {
      final start = timeline.gopStart[target];
      if (start < 0) {
        throw const FormatException('H.264 picture has no preceding IDR');
      }
      if (start != group) {
        decoder = H264StreamDecoder(AvcConfiguration(_avcConfig));
        group = start;
        next = start;
      }
      while (next <= target) {
        final packet = timeline.decodeOrder[next++];
        final picture = decoder!.decode(_read(packet));
        if (next - 1 == target) {
          if (picture == null) {
            throw const FormatException('Invalid H.264 video frame');
          }
          yield (packet: packet, frame: picture.rgb());
        }
      }
    }
  }

  image.Image? cover() {
    if (_avi != null) return null;
    final matroska = _matroska;
    final covers = matroska == null
        ? isoCovers(_iso!)
        : matroskaCovers(matroska);
    for (final packet in covers) {
      if (packet.size <= 0 || packet.size > 32 * 1024 * 1024) continue;
      final frame = image.decodeImage(file.read(packet.offset, packet.size));
      if (frame != null) return _rgb(frame);
    }
    return null;
  }

  Uint8List _read(FramePacket packet) {
    if (packet.size <= 0 || packet.size > 64 * 1024 * 1024) {
      throw const FormatException('Invalid video frame size');
    }
    return file.read(packet.offset, packet.size);
  }

  image.Image decode(FramePacket packet) {
    final bytes = _read(packet);
    if (codec == 'h264') {
      return _h264.decode(bytes)?.rgb() ??
          decodeSelected([packet]).single.frame;
    }
    final frame = switch (codec) {
      'mjpeg' => image.decodeJpg(bytes),
      'png' => image.decodePng(bytes),
      'vp8' => _vp8Keyframe(bytes),
      'rawvideo' => _avi?.decodeBitmap(bytes),
      _ => null,
    };
    if (frame == null) throw FormatException('Invalid $codec video frame');
    return _rgb(frame);
  }

  image.Image _rgb(image.Image frame) =>
      frame.convert(format: image.Format.uint8, numChannels: 3);

  image.Image? _vp8Keyframe(Uint8List bytes) {
    if (bytes.length < 10 || bytes[0] & 1 != 0) return null;
    // WebP's VP8 chunk carries one intra-coded VP8 frame.
    final riff = Uint8List(20 + bytes.length + (bytes.length & 1));
    riff.setRange(0, 4, 'RIFF'.codeUnits);
    riff.setRange(8, 16, 'WEBPVP8 '.codeUnits);
    final header = ByteData.sublistView(riff);
    header.setUint32(4, riff.length - 8, Endian.little);
    header.setUint32(16, bytes.length, Endian.little);
    riff.setRange(20, 20 + bytes.length, bytes);
    return image.decodeWebP(riff);
  }
}

typedef _H264Timeline = ({
  List<FramePacket> decodeOrder,
  List<FramePacket> presentation,
  Map<FramePacket, int> index,
  List<int> gopStart,
});
