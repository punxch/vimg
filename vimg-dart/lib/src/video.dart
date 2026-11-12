import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as image;

import 'avi.dart';
import 'av1/access_units.dart';
import 'av1/frame_header.dart';
import 'av1/picture_decoder.dart';
import 'binary_file.dart';
import 'frame_packet.dart';
import 'h264/access_unit.dart';
import 'h264/idr_picture.dart';
import 'hevc/access_unit.dart';
import 'hevc/decode_picture.dart';
import 'iso_media.dart';
import 'matroska.dart';
import 'matroska_frames.dart';
import 'metadata.dart';
import 'prores.dart';
import 'video_configuration.dart';
import 'yuv_image.dart';

part 'video_workers.dart';

typedef _SelectedFrame = ({
  FramePacket packet,
  image.Image frame,
  image.Image? original,
});

final class Video {
  Video(this.path) : _input = File(path).openSync() {
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

  final String path;
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

  bool get usesReferencePictures =>
      codec == 'h264' || codec == 'hevc' || codec == 'av1';

  bool get scalesBeforeRgb => usesReferencePictures || codec == 'prores';

  void close() => _input.closeSync();

  late final Uint8List _avcConfig = _configuration('h264');
  late final H264IdrDecoder _h264 = H264IdrDecoder(
    AvcConfiguration(_avcConfig),
  );
  late final _VideoTimeline _timeline = _indexVideo();
  late final Uint8List _hevcConfig = _configuration('hevc');
  late final HevcIntraDecoder _hevc = HevcIntraDecoder(
    HevcConfiguration(_hevcConfig),
  );
  late final Uint8List _av1Config = _av1Configuration();
  late final _av1Timeline = _indexAv1();

  Uint8List _av1Configuration() {
    final matroska = _matroska;
    final iso = _iso;
    final config = matroska != null
        ? matroskaVideoConfiguration(matroska, 'av1')
        : (iso == null ? null : isoVideoConfiguration(iso, 'av1'));
    if (config == null) return Uint8List(0);
    if (config.first != 0x81) {
      throw const FormatException('Invalid AV1 codec configuration');
    }
    return Uint8List.sublistView(config, 4);
  }

  Uint8List _configuration(String codec) {
    final matroska = _matroska;
    final iso = _iso;
    final config = matroska != null
        ? matroskaVideoConfiguration(matroska, codec)
        : (iso != null ? isoVideoConfiguration(iso, codec) : null);
    if (config == null) {
      final name = codec == 'h264' ? 'H.264' : 'HEVC';
      throw UnsupportedError(
        '$name requires a Matroska or MP4 codec configuration',
      );
    }
    return config;
  }

  Iterable<FramePacket> packets({bool preview = false}) {
    if (codec == 'h264') {
      return preview ? _h264Keyframes() : _timeline.presentation;
    }
    if (codec == 'hevc') {
      final configuration = _hevc.configuration;
      if (preview) {
        return _containerPackets(true).where(
          (packet) => configuration.containsRandomAccess(
            packet.offset,
            packet.size,
            file.unsigned,
          ),
        );
      }
      return _timeline.presentation;
    }
    if (codec == 'av1') {
      return preview
          ? _containerPackets(true)
          : _av1Timeline.timeline.presentation;
    }
    final keyframes = preview && codec == 'vp8';
    final avi = _avi;
    final bitmap = codec == 'rawvideo' && avi?.supportsBitmap == true;
    if (codec != 'mjpeg' &&
        codec != 'png' &&
        codec != 'prores' &&
        !keyframes &&
        !bitmap) {
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

  ({_VideoTimeline timeline, Map<int, Uint8List> configurations}) _indexAv1() {
    final units = Av1AccessUnits()..configure(_av1Config);
    final decodeOrder = <FramePacket>[], startPositions = <int>[];
    final shown = <FramePacket>{};
    final index = <FramePacket, int>{};
    final configurations = <int, Uint8List>{};
    var start = -1;
    final presentation =
        _containerPackets(
          false,
          onSample: (packet, _) {
            final position = decodeOrder.length;
            var first = true, displays = 0;
            for (final frame in units.readSample(_read(packet))) {
              if (first &&
                  frame.header.type == Av1FrameType.key &&
                  frame.shown &&
                  frame.syntax.existingSlot == null) {
                start = position;
                configurations[start] =
                    units.sequenceConfiguration ?? _av1Config;
              }
              first = false;
              if (frame.shown) displays++;
            }
            if (displays > 1)
              throw const FormatException(
                'Multiple AV1 display frames in a sample',
              );
            if (displays == 1 && start >= 0) shown.add(packet);
            index[packet] = position;
            decodeOrder.add(packet);
            startPositions.add(start);
          },
        ).where(shown.contains).toList()..sort((a, b) {
          final byTime = a.seconds.compareTo(b.seconds);
          return byTime == 0 ? index[a]!.compareTo(index[b]!) : byTime;
        });
    return (
      timeline: (
        decodeOrder: decodeOrder,
        presentation: presentation,
        index: index,
        gopStart: startPositions,
      ),
      configurations: configurations,
    );
  }

  _VideoTimeline _indexVideo() {
    final hevc = codec == 'hevc' ? _hevc.configuration : null;
    final avc = hevc == null ? _h264.configuration : null;
    final decodeOrder = <FramePacket>[];
    final index = <FramePacket, int>{};
    final gopStart = <int>[];
    var start = -1, previous = -1;
    final presentation = _containerPackets(
      false,
      onSample: (packet, sync) {
        final position = decodeOrder.length;
        final header = hevc?.pictureHeader(
          packet.offset,
          packet.size,
          file.unsigned,
        );
        if (header?.randomAccess == true ||
            (avc != null && sync && _isIdr(avc, packet))) {
          // RASL pictures following a CRA can still refer across it.
          previous = header?.type == 21 ? start : -1;
          start = position;
        }
        index[packet] = position;
        decodeOrder.add(packet);
        gopStart.add(header?.rasl == true ? previous : start);
      },
    ).toList();
    if (hevc != null) {
      presentation.removeWhere((packet) => gopStart[index[packet]!] < 0);
    }
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

  Iterable<_SelectedFrame> decodeSelected(
    Iterable<FramePacket> selected, {
    YuvImageScaler? scaler,
    bool includeOriginal = false,
  }) sync* {
    for (final run in _decodeRuns(selected)) {
      yield* _decodeRun(run, scaler, includeOriginal);
    }
  }

  /// Split exactly where the serial decoder would restart. In particular, an
  /// HEVC leading picture can require decoding across a random-access point.
  Iterable<_DecodeRun> _decodeRuns(Iterable<FramePacket> selected) sync* {
    if (!usesReferencePictures) {
      for (final packet in selected) {
        yield (packets: [packet], targets: const [0], configuration: null);
      }
      return;
    }
    final av1 = codec == 'av1';
    final timeline = av1 ? _av1Timeline.timeline : _timeline;
    final targets = {
      for (final packet in selected)
        timeline.index[packet] ??
            (throw FormatException('Unknown ${av1 ? 'AV1 ' : ''}video packet')),
    }.toList()..sort();
    var start = -1, end = -1;
    var wanted = <int>[];
    _DecodeRun run() => (
      packets: timeline.decodeOrder.sublist(start, end + 1),
      targets: wanted,
      configuration: av1 ? _av1Timeline.configurations[start]! : null,
    );
    for (final target in targets) {
      final anchor = timeline.gopStart[target];
      if (anchor < 0) {
        throw FormatException(
          av1
              ? 'AV1 picture has no preceding keyframe'
              : 'Picture has no preceding random-access point',
        );
      }
      if (start < 0 ||
          (av1 ? anchor != start : anchor < start || anchor > end)) {
        if (start >= 0) yield run();
        start = anchor;
        wanted = [];
      }
      wanted.add(target - start);
      end = target;
    }
    if (start >= 0) yield run();
  }

  Iterable<_SelectedFrame> _decodeRun(
    _DecodeRun run,
    YuvImageScaler? scaler,
    bool includeOriginal,
  ) sync* {
    if (!usesReferencePictures) {
      final packet = run.packets.single;
      final _RenderPicture render;
      if (codec == 'prores') {
        final keepAlpha =
            includeOriginal ||
            (scaler?.width == null && scaler?.height == null);
        final picture = _proRes(packet, preserveAlpha: keepAlpha);
        render = ({scaler}) => picture.rgb(
          scaler: scaler,
          includeAlpha: scaler?.width == null && scaler?.height == null,
        );
      } else {
        final source = decode(packet);
        render = ({scaler}) => scaler?.filterRgb(source) ?? source;
      }
      final frame = render(scaler: scaler);
      final unscaled = scaler?.unscaled;
      yield (
        packet: packet,
        frame: frame,
        original: !includeOriginal
            ? null
            : identical(unscaled, scaler)
            ? frame
            : render(scaler: unscaled),
      );
      return;
    }
    final readPicture = _pictureReader(run.configuration);
    var target = 0;
    for (final (i, packet) in run.packets.indexed) {
      final selected = i == run.targets[target];
      final render = readPicture(_read(packet), selected);
      if (!selected) continue;
      if (render == null) {
        throw FormatException(
          codec == 'av1'
              ? 'AV1 sample has no display picture'
              : 'Invalid $codec video frame',
        );
      }
      final frame = render(scaler: scaler);
      final unscaled = scaler?.unscaled;
      final original = includeOriginal
          ? (identical(unscaled, scaler) ? frame : render(scaler: unscaled))
          : null;
      yield (packet: packet, frame: frame, original: original);
      target++;
    }
  }

  _RenderPicture? Function(Uint8List, bool) _pictureReader(
    Uint8List? configuration,
  ) {
    switch (codec) {
      case 'av1':
        final units = Av1AccessUnits()..configure(configuration!);
        final decoder = Av1StreamDecoder();
        return (bytes, selected) {
          Av1Picture? displayed;
          for (final frame in units.readSample(bytes)) {
            final picture = decoder.decode(frame);
            if (selected && frame.shown) {
              displayed = applyAv1FilmGrain(
                picture,
                frame.header.parameters.filmGrain,
              );
            }
          }
          return displayed?.rgb;
        };
      case 'hevc':
        final decoder = HevcStreamDecoder(HevcConfiguration(_hevcConfig));
        return (bytes, selected) {
          final picture = decoder.decode(bytes);
          return selected ? picture?.rgb : null;
        };
      default:
        final decoder = H264StreamDecoder(AvcConfiguration(_avcConfig));
        return (bytes, selected) {
          final picture = decoder.decode(bytes);
          return selected ? picture?.rgb : null;
        };
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

  image.Image decode(FramePacket packet, {bool preview = false}) {
    if (codec == 'av1' && !preview)
      return decodeSelected([packet]).single.frame;
    if (codec == 'prores') {
      return _proRes(packet, preserveAlpha: !preview).rgb();
    }
    final bytes = _read(packet);
    if (codec == 'h264') {
      return _h264.decode(bytes)?.rgb() ??
          decodeSelected([packet]).single.frame;
    }
    if (codec == 'hevc') {
      return _hevc.decode(bytes)?.rgb() ??
          decodeSelected([packet]).single.frame;
    }
    if (codec == 'av1') {
      final decoder = Av1AccessUnits()..configure(_av1Config);
      for (final frame in decoder.readSample(bytes)) {
        if (frame.header.type.intra && frame.shown) {
          return decodeAv1IntraImage(frame);
        }
      }
      throw const FormatException('No independently decodable AV1 picture');
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

  ProResPicture _proRes(FramePacket packet, {required bool preserveAlpha}) =>
      decodeProRes(
        _read(packet),
        allowBareFrame: _matroska != null,
        preserveAlpha: preserveAlpha,
      );

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

typedef _VideoTimeline = ({
  List<FramePacket> decodeOrder,
  List<FramePacket> presentation,
  Map<FramePacket, int> index,
  List<int> gopStart,
});

typedef _RenderPicture = image.Image Function({YuvImageScaler? scaler});
typedef _DecodeRun = ({
  List<FramePacket> packets,
  List<int> targets,
  Uint8List? configuration,
});
