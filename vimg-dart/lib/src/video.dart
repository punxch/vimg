import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;

import 'avi.dart';
import 'binary_file.dart';
import 'frame_packet.dart';
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

  Iterable<FramePacket> packets({bool preview = false}) {
    final keyframes = preview && codec == 'vp8';
    final avi = _avi;
    final bitmap = codec == 'rawvideo' && avi?.supportsBitmap == true;
    if (codec != 'mjpeg' && codec != 'png' && !keyframes && !bitmap) {
      throw UnsupportedError('Pure Dart decoding for $codec is unavailable');
    }
    if (avi != null) return avi.packets();
    final matroska = _matroska;
    return matroska == null
        ? isoFrames(_iso!, keyframes: keyframes)
        : matroskaFrames(matroska, keyframes: keyframes);
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
