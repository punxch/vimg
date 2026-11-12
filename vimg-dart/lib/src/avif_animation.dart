import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;

import 'av1/access_units.dart';
import 'av1/picture_decoder.dart';
import 'binary_file.dart';
import 'frame_packet.dart';
import 'iso_media.dart';

/// AVIF animation sample table and the timing of one playback cycle.
final class AvifAnimation {
  factory AvifAnimation.open(String path) {
    final handle = File(path).openSync();
    try {
      final file = BinaryFile(handle);
      final media = IsoMedia(file);
      final boxes = media.boxes(0, file.length).toList();
      final type = boxes.where((b) => b.type == 'ftyp').firstOrNull;
      if (type == null || !_avifBrand(media, type))
        throw const FormatException('Expected an AVIF file');
      final movie = media.movie();
      final primary = boxes.any((b) => b.type == 'meta');
      AvifAnimation? selected;
      var index = primary ? 1 : 0;
      for (final track
          in media.children(movie).where((b) => b.type == 'trak')) {
        final streamIndex = index++;
        final mdia = media.child(track, 'mdia');
        final handler = media.child(mdia, 'hdlr');
        if (handler == null) continue;
        media.requireBytes(handler, 12);
        final name = media.tag(handler.data + 8);
        if (name != 'vide' && name != 'pict') continue;
        final table = media.sampleTable(mdia);
        final description = media.sampleDescription(table);
        if (description == null || description.type != 'av01') continue;
        media.requireBytes(description, 78);
        final width = file.unsigned(description.data + 24, 2);
        final height = file.unsigned(description.data + 26, 2);
        final timing = media.timing(media.child(mdia, 'mdhd'));
        final duration = timing?.duration;
        if (width == 0 || height == 0 || duration == null || duration <= 0)
          throw const FormatException(
            'Invalid AVIF animation dimensions or duration',
          );
        final samples = <FramePacket>[];
        final packets = <FramePacket>{};
        for (final packet in isoFrames(
          media,
          selectedTrack: track,
          onSample: (packet, _) {
            if (samples.length == 100000)
              throw const FormatException(
                'AVIF animation exceeds 100000 samples',
              );
            samples.add(packet);
          },
        )) {
          packets.add(packet);
        }
        if (packets.isEmpty || packets.length < (selected?.frameCount ?? 0))
          continue;
        samples.length = samples.lastIndexWhere(packets.contains) + 1;
        final configuration = media
            .children(description, skip: 78)
            .where((box) => box.type == 'av1C')
            .firstOrNull;
        if (configuration == null)
          throw const FormatException('Missing AVIF AV1 configuration');
        media.requireBytes(configuration, 4);
        if (file.unsigned(configuration.data, 1) != 0x81 ||
            configuration.end - configuration.data > 1024 * 1024)
          throw const FormatException('Invalid AVIF AV1 configuration');
        final config = file.read(
          configuration.data + 4,
          configuration.end - configuration.data - 4,
        );
        selected = AvifAnimation._(
          handle,
          file,
          samples,
          packets,
          config,
          width,
          height,
          timing!.scale,
          duration,
          streamIndex,
        );
      }
      return selected ??
          (throw const FormatException('AVIF file has no animation track'));
    } catch (_) {
      handle.closeSync();
      rethrow;
    }
  }

  AvifAnimation._(
    this._handle,
    this._file,
    this._samples,
    this._packets,
    this._config,
    this.width,
    this.height,
    this._timescale,
    this._duration,
    this.streamIndex,
  );

  final RandomAccessFile _handle;
  final BinaryFile _file;
  final List<FramePacket> _samples;
  final Set<FramePacket> _packets;
  final Uint8List _config;
  final int width, height, _timescale, _duration, streamIndex;

  int get frameCount => _packets.length;
  double get durationSeconds => _duration / _timescale;
  double get framesPerSecond => frameCount * _timescale / _duration;
  String get frameRate {
    final numerator = frameCount * _timescale;
    final common = numerator.gcd(_duration);
    return '${numerator ~/ common}/${_duration ~/ common}';
  }

  /// Decode-order AV1 frames, including hidden frames and pre-roll trimmed by
  /// the track edit. Only the shown frame of a visible sample is presented.
  Iterable<({Av1CodedFrame frame, FramePacket packet, bool present})>
  codedFrames() sync* {
    final units = Av1AccessUnits()..configure(_config);
    for (final packet in _samples) {
      if (packet.size > 64 * 1024 * 1024)
        throw const FormatException('Oversized AVIF animation sample');
      final visible = _packets.contains(packet);
      var displayed = 0;
      for (final frame in units.readSample(
        _file.read(packet.offset, packet.size),
      )) {
        if (frame.shown) displayed++;
        yield (frame: frame, packet: packet, present: visible && frame.shown);
      }
      if (visible && displayed != 1)
        throw const FormatException('AVIF sample must display one frame');
    }
  }

  Iterable<image.Image> decodeFrames() sync* {
    final decoder = Av1StreamDecoder();
    for (final sample in codedFrames()) {
      final picture = decoder.decode(sample.frame);
      if (!sample.present) continue;
      final frame = decoder.display(sample.frame, picture);
      if (frame.width != width || frame.height != height)
        throw const FormatException(
          'AVIF sample dimensions differ from its track',
        );
      yield frame;
    }
  }

  void close() => _handle.closeSync();
}

bool _avifBrand(IsoMedia media, MediaBox box) {
  media.requireBytes(box, 8);
  if ((box.end - box.data) % 4 != 0)
    throw const FormatException('Invalid AVIF brand list');
  for (var at = box.data; at < box.end; at += 4) {
    if (at == box.data + 4) continue; // minor_version
    final tag = media.tag(at);
    if (tag == 'avif' || tag == 'avis') return true;
  }
  return false;
}
