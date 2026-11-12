import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;

import 'avi.dart';
import 'binary_file.dart';
import 'frame_packet.dart';
import 'h264/access_unit.dart';
import 'h264/container.dart';
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

  late final H264IdrDecoder _h264 = _openH264();

  H264IdrDecoder _openH264() {
    final matroska = _matroska;
    final iso = _iso;
    final config = matroska != null
        ? matroskaAvcConfiguration(matroska)
        : (iso != null ? isoAvcConfiguration(iso) : null);
    if (config == null)
      throw UnsupportedError(
        'H.264 requires a Matroska or MP4 AVC configuration',
      );
    return H264IdrDecoder(AvcConfiguration(config));
  }

  Iterable<FramePacket> packets({bool preview = false}) {
    if (codec == 'h264') return _h264Packets(preview);
    final keyframes = preview && codec == 'vp8';
    final avi = _avi;
    final bitmap = codec == 'rawvideo' && avi?.supportsBitmap == true;
    if (codec != 'mjpeg' && codec != 'png' && !keyframes && !bitmap) {
      throw UnsupportedError('Pure Dart decoding for $codec is unavailable');
    }
    if (avi != null) return avi.packets();
    return _containerPackets(keyframes);
  }

  Iterable<FramePacket> _containerPackets(bool keyframes) {
    final matroska = _matroska;
    return matroska == null
        ? isoFrames(_iso!, keyframes: keyframes)
        : matroskaFrames(matroska, keyframes: keyframes);
  }

  Iterable<FramePacket> _h264Packets(bool preview) sync* {
    final configuration = _h264.configuration;
    for (final packet in _containerPackets(preview)) {
      if (configuration.containsIdr(
        packet.offset,
        packet.size,
        file.unsigned,
      )) {
        yield packet;
      } else if (!preview) {
        throw UnsupportedError('H.264 inter-picture decoding is unavailable');
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

  image.Image decode(FramePacket packet) {
    if (packet.size <= 0 || packet.size > 64 * 1024 * 1024) {
      throw const FormatException('Invalid video frame size');
    }
    final bytes = file.read(packet.offset, packet.size);
    final frame = switch (codec) {
      'mjpeg' => image.decodeJpg(bytes),
      'png' => image.decodePng(bytes),
      'vp8' => _vp8Keyframe(bytes),
      'h264' => _h264.decode(bytes)?.rgb(),
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
