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
import 'hevc/nal.dart';
import 'iso_media.dart';
import 'matroska.dart';
import 'matroska_frames.dart';
import 'metadata.dart';
import 'mpeg12/decode.dart';
import 'mpeg12/syntax.dart';
import 'mpeg_systems.dart';
import 'nal_parameter_sets.dart';
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
        _systems = MpegSystemsVideo.detect(file);
        if (_systems == null) _iso = IsoMedia(file);
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
  MpegSystemsVideo? _systems;

  late final VideoMetadata metadata =
      _matroska?.metadata() ??
      _avi?.metadata() ??
      _systems?.metadata() ??
      _iso!.metadata();

  String get codec =>
      metadata.streams.where((stream) => !stream.attached).firstOrNull?.codec ??
      (throw const FormatException('No video stream'));

  // Workers only need the codec family from the container headers.
  String get _decodeCodec => _systems?.programCodec ?? codec;

  bool get usesReferencePictures {
    final name = _decodeCodec;
    return name == 'h264' ||
        name == 'hevc' ||
        name == 'av1' ||
        isMpegVideo(name);
  }

  bool get scalesBeforeRgb => usesReferencePictures || codec == 'prores';

  void close() => _input.closeSync();

  late final _nalTimeline = _indexNalVideo();
  final _previewNalConfigurations = <FramePacket, _NalConfiguration>{};
  final _previewAv1Configurations = <FramePacket, Uint8List>{};
  late final _av1Timeline = _indexAv1();
  late final _mpegTimeline = _indexMpeg();

  Uint8List _av1Configuration([MediaBox? description]) {
    final matroska = _matroska;
    final iso = _iso;
    final config = matroska != null
        ? matroskaVideoConfiguration(matroska, 'av1')
        : (iso == null
              ? null
              : isoVideoConfiguration(iso, 'av1', description: description));
    if (config == null) return Uint8List(0);
    if (config.first != 0x81) {
      throw const FormatException('Invalid AV1 codec configuration');
    }
    return Uint8List.sublistView(config, 4);
  }

  Uint8List _configuration(String codec, [MediaBox? description]) {
    final matroska = _matroska;
    final iso = _iso;
    final config = matroska != null
        ? matroskaVideoConfiguration(matroska, codec)
        : (iso != null
              ? isoVideoConfiguration(iso, codec, description: description)
              : null);
    if (config == null) {
      final name = codec == 'h264' ? 'H.264' : 'HEVC';
      throw UnsupportedError(
        '$name requires a Matroska or MP4 codec configuration',
      );
    }
    return config;
  }

  Iterable<FramePacket> packets({bool preview = false}) {
    final systems = _systems;
    if (systems != null) {
      return preview
          ? systems.packets(true)
          : (isMpegVideo(codec)
                    ? _mpegTimeline.timeline
                    : _nalTimeline.timeline)
                .presentation;
    }
    if (isMpegVideo(codec)) {
      final indexed = _mpegTimeline;
      return preview
          ? indexed.timeline.presentation.where(
              (packet) => indexed.configurations.containsKey(
                indexed.timeline.index[packet],
              ),
            )
          : indexed.timeline.presentation;
    }
    if (codec == 'h264' || codec == 'hevc') {
      return preview
          ? _nalPackets(preview: true)
          : _nalTimeline.timeline.presentation;
    }
    if (codec == 'av1') {
      return preview
          ? _av1PreviewPackets()
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
    void Function(MediaBox)? onDescription,
  }) {
    final systems = _systems;
    if (systems != null) return systems.packets(keyframes, onSample: onSample);
    final matroska = _matroska;
    if (matroska != null) {
      return matroskaFrames(matroska, keyframes: keyframes, onSample: onSample);
    }
    final iso = _iso!;
    return isoFrames(
      iso,
      keyframes: keyframes,
      onSample: onSample,
      onDescription: (entry) {
        if (iso.videoCodec(entry) != codec) {
          throw const FormatException(
            'ISO media video codec changes within a track',
          );
        }
        onDescription?.call(entry);
      },
    );
  }

  Iterable<FramePacket> _av1PreviewPackets() sync* {
    var configuration = _iso == null ? _av1Configuration() : Uint8List(0);
    for (final packet in _containerPackets(
      true,
      onDescription: (entry) => configuration = _av1Configuration(entry),
    )) {
      _previewAv1Configurations[packet] = configuration;
      yield packet;
    }
  }

  ({_VideoTimeline timeline, Map<int, Uint8List> configurations}) _indexAv1() {
    var configuration = _iso == null ? _av1Configuration() : Uint8List(0);
    var units = Av1AccessUnits()..configure(configuration);
    final decodeOrder = <FramePacket>[], startPositions = <int>[];
    final shown = <FramePacket>{};
    final index = <FramePacket, int>{};
    final configurations = <int, Uint8List>{};
    var start = -1;
    var newDescription = false;
    final presentation =
        _containerPackets(
          false,
          onDescription: (entry) {
            newDescription = decodeOrder.isNotEmpty;
            configuration = _av1Configuration(entry);
            units = Av1AccessUnits()..configure(configuration);
          },
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
                    units.sequenceConfiguration ?? configuration;
              }
              first = false;
              if (frame.shown) displays++;
            }
            if (displays > 1)
              throw const FormatException(
                'Multiple AV1 display frames in a sample',
              );
            if (newDescription && !first && start != position) {
              throw const FormatException(
                'AV1 sample description changes outside a keyframe',
              );
            }
            if (!first) newDescription = false;
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

  /// A sample may introduce parameters used only by a later picture.
  /// Keep the parameters already available before each random-access sample
  /// so the decoder can then read that sample's own NALs in their original order.
  Iterable<FramePacket> _nalPackets({
    bool preview = false,
    void Function(FramePacket, int?, bool, _NalConfiguration?, bool)? onSample,
  }) sync* {
    final systems = _systems;
    final isHevc = codec == 'hevc';
    Uint8List? record;
    HevcConfiguration? hevc;
    AvcConfiguration? avc;
    var parameters = NalParameterSets();
    var newDescription = false, hasPicture = false;
    void configure([MediaBox? description]) {
      record = _configuration(codec, description);
      if (isHevc) {
        hevc = HevcConfiguration(record!);
      } else {
        avc = AvcConfiguration(record!);
      }
      parameters = NalParameterSets(
        lengthBytes: hevc?.lengthBytes ?? avc!.lengthBytes,
      );
      newDescription = hasPicture;
    }

    if (_matroska != null) configure();
    void parameterSet(int start, int length) {
      final nal = file.read(start, length);
      final key = hevc == null ? avc!.store(nal) : hevc!.store(HevcNal(nal));
      parameters.update(key!, nal);
    }

    int? type;
    var keyframe = false;
    _NalConfiguration? configuration;
    for (final packet in _containerPackets(
      false,
      onDescription: configure,
      onSample: (packet, sync) {
        final before = parameters.snapshot();
        final header = hevc?.pictureHeader(
          packet.offset,
          packet.size,
          file.unsigned,
          onParameterSet: parameterSet,
        );
        type =
            systems?.nalType(packet) ??
            header?.type ??
            avc?.pictureType(
              packet.offset,
              packet.size,
              file.unsigned,
              onParameterSet: parameterSet,
            );
        final random = systems != null
            ? sync
            : isHevc
            ? header?.randomAccess == true
            : sync && type == 5;
        keyframe = sync && random;
        configuration = random
            ? (
                record: record,
                parameterSets: systems?.configurationAt(packet) ?? before,
              )
            : null;
        if (type != null) {
          if (newDescription && !random) {
            throw const FormatException(
              'AVC or HEVC sample description changes outside a random-access picture',
            );
          }
          onSample?.call(packet, type, random, configuration, newDescription);
          newDescription = false;
          hasPicture = true;
        } else {
          onSample?.call(packet, type, random, configuration, false);
        }
      },
    )) {
      if (preview) {
        if (!keyframe) continue;
        _previewNalConfigurations[packet] = configuration!;
      } else if (type == null) {
        continue;
      }
      yield packet;
    }
  }

  ({
    _VideoTimeline timeline,
    Map<int, _NalConfiguration> configurations,
    Map<int, int> sections,
  })
  _indexNalVideo() {
    final isHevc = codec == 'hevc';
    final decodeOrder = <FramePacket>[];
    final index = <FramePacket, int>{};
    final gopStart = <int>[];
    final configurations = <int, _NalConfiguration>{};
    final sections = <int, int>{};
    var start = -1, previous = -1, section = 0;
    final presentation = _nalPackets(
      onSample: (packet, type, randomAccess, configuration, newDescription) {
        final position = decodeOrder.length;
        if (randomAccess) {
          // RASL pictures following a CRA can still refer across it.
          previous = isHevc && type == 21 && !newDescription ? start : -1;
          start = position;
          if (newDescription) section = start;
          configurations[start] = configuration!;
          sections[start] = section;
        }
        index[packet] = position;
        decodeOrder.add(packet);
        gopStart.add(isHevc && (type == 8 || type == 9) ? previous : start);
      },
    ).toList();
    if (isHevc) {
      presentation.removeWhere((packet) => gopStart[index[packet]!] < 0);
    }
    presentation.sort((a, b) {
      final byTime = a.seconds.compareTo(b.seconds);
      return byTime == 0 ? index[a]!.compareTo(index[b]!) : byTime;
    });
    return (
      timeline: (
        decodeOrder: decodeOrder,
        presentation: presentation,
        index: index,
        gopStart: gopStart,
      ),
      configurations: configurations,
      sections: sections,
    );
  }

  ({
    _VideoTimeline timeline,
    Map<int, Uint8List> configurations,
    Map<int, int> sections,
  })
  _indexMpeg() {
    final systems = _systems;
    var headers = MpegHeaders();
    final matroska = _matroska;
    void configure(Uint8List? configuration) {
      headers = MpegHeaders();
      if (configuration == null) return;
      for (final unit in mpegStartCodes(configuration)) {
        headers.add(
          unit.code,
          Uint8List.sublistView(configuration, unit.data, unit.end),
        );
      }
    }

    if (matroska != null)
      configure(matroskaVideoConfiguration(matroska, codec));
    final decodeOrder = <FramePacket>[], gopStart = <int>[];
    final index = <FramePacket, int>{}, configurations = <int, Uint8List>{};
    final sections = <int, int>{};
    var start = -1, bStart = -1, section = 0;
    MpegPictureInfo pictureInfo(FramePacket packet) {
      if (systems != null) return systems.mpegPicture(packet);
      final bytes = _read(packet);
      MpegPictureInfo? picture;
      var flags = 0;
      for (final unit in mpegStartCodes(bytes)) {
        if (unit.code >= 1 && unit.code <= 0xaf) break;
        if (unit.code == 0) {
          picture = mpegPictureInfo(
            Uint8List.sublistView(bytes, unit.data, unit.end),
            flags,
          );
          if (picture.type == 1)
            configurations[decodeOrder.length] = headers.configuration();
        } else if (unit.code == 0xb8 && unit.end - unit.data >= 4) {
          flags = bytes[unit.data + 3];
        } else {
          headers.add(
            unit.code,
            Uint8List.sublistView(bytes, unit.data, unit.end),
          );
        }
      }
      return picture ??
          (throw const FormatException('Missing MPEG video picture'));
    }

    final presentation =
        _containerPackets(
            false,
            onDescription: (entry) {
              configure(_iso!.mpegVideoConfiguration(description: entry));
              section = decodeOrder.length;
              start = bStart = -1;
            },
            onSample: (packet, _) {
              final position = decodeOrder.length;
              final picture = pictureInfo(packet);
              if (section > 0 && position == section && picture.type != 1) {
                throw const FormatException(
                  'MPEG video sample description changes outside an I-picture',
                );
              }
              switch (picture.type) {
                case 1:
                  // Leading B-pictures in an open GOP can use the previous GOP.
                  bStart = picture.closedGop
                      ? position
                      : (picture.brokenLink ? -1 : start);
                  start = position;
                  sections[start] = section;
                  if (systems != null) {
                    configurations[position] = systems.configurationAt(packet)!;
                  }
                case 2:
                  bStart = start;
                case 3:
                  break;
                default:
                  throw UnsupportedError(
                    'MPEG picture coding type ${picture.type} is unavailable',
                  );
              }
              index[packet] = position;
              decodeOrder.add(packet);
              gopStart.add(picture.type == 3 ? bStart : start);
            },
          ).where((packet) => gopStart[index[packet]!] >= 0).toList()
          ..sort((a, b) {
            final byTime = a.seconds.compareTo(b.seconds);
            return byTime == 0 ? index[a]!.compareTo(index[b]!) : byTime;
          });
    return (
      timeline: (
        decodeOrder: decodeOrder,
        presentation: presentation,
        index: index,
        gopStart: gopStart,
      ),
      configurations: configurations,
      sections: sections,
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
        yield (
          packets: [packet],
          targets: const [0],
          configuration: null,
          nalConfiguration: null,
        );
      }
      return;
    }
    final av1 = codec == 'av1';
    final mpeg = isMpegVideo(codec);
    final timeline = av1
        ? _av1Timeline.timeline
        : mpeg
        ? _mpegTimeline.timeline
        : _nalTimeline.timeline;
    final sections = av1
        ? const <int, int>{}
        : mpeg
        ? _mpegTimeline.sections
        : _nalTimeline.sections;
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
      configuration: av1
          ? _av1Timeline.configurations[start]!
          : mpeg
          ? _mpegTimeline.configurations[start]!
          : null,
      nalConfiguration: av1 || mpeg
          ? null
          : _nalTimeline.configurations[start]!,
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
          (av1 ? anchor != start : anchor < start || anchor > end) ||
          sections[anchor] != sections[start]) {
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
    final readPicture = _pictureReader(run);
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

  _RenderPicture? Function(Uint8List, bool) _pictureReader(_DecodeRun run) {
    switch (_decodeCodec) {
      case 'av1':
        final units = Av1AccessUnits()..configure(run.configuration!);
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
        final decoder = HevcStreamDecoder(
          _hevcDecoderConfig(run.nalConfiguration!),
        );
        return (bytes, selected) {
          final picture = decoder.decode(bytes);
          return selected ? picture?.rgb : null;
        };
      case 'mpeg1video' || 'mpeg2video':
        final decoder = MpegStreamDecoder(run.configuration);
        return (bytes, selected) {
          if (selected) return decoder.decode(bytes).rgb;
          decoder.advance(bytes);
          return null;
        };
      default:
        final decoder = H264StreamDecoder(
          _avcDecoderConfig(run.nalConfiguration!),
        );
        return (bytes, selected) {
          final picture = decoder.decode(bytes);
          return selected ? picture?.rgb : null;
        };
    }
  }

  HevcConfiguration _hevcDecoderConfig(_NalConfiguration state) {
    final (:record, :parameterSets) = state;
    if (record == null) return HevcConfiguration.inBand(parameterSets!);
    final config = HevcConfiguration(record);
    if (parameterSets != null) config.applyParameterSets(parameterSets);
    return config;
  }

  AvcConfiguration _avcDecoderConfig(_NalConfiguration state) {
    final (:record, :parameterSets) = state;
    if (record == null) return AvcConfiguration.inBand(parameterSets!);
    final config = AvcConfiguration(record);
    if (parameterSets != null) config.applyParameterSets(parameterSets);
    return config;
  }

  image.Image? cover() {
    if (_avi != null || _systems != null) return null;
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
    return _systems?.read(packet) ?? file.read(packet.offset, packet.size);
  }

  image.Image decode(FramePacket packet, {bool preview = false}) {
    if (usesReferencePictures &&
        (_systems != null ||
            !preview ||
            isMpegVideo(codec) ||
            (codec == 'av1'
                ? !_previewAv1Configurations.containsKey(packet)
                : !_previewNalConfigurations.containsKey(packet)))) {
      return decodeSelected([packet]).single.frame;
    }
    if (codec == 'prores') {
      return _proRes(packet, preserveAlpha: !preview).rgb();
    }
    final bytes = _read(packet);
    if (codec == 'h264') {
      final config = _avcDecoderConfig(_previewNalConfigurations[packet]!);
      return H264IdrDecoder(config).decode(bytes)?.rgb() ??
          decodeSelected([packet]).single.frame;
    }
    if (codec == 'hevc') {
      final config = _hevcDecoderConfig(_previewNalConfigurations[packet]!);
      return HevcIntraDecoder(config).decode(bytes)?.rgb() ??
          decodeSelected([packet]).single.frame;
    }
    if (codec == 'av1') {
      final decoder = Av1AccessUnits()
        ..configure(_previewAv1Configurations[packet]!);
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
typedef _NalConfiguration = ({Uint8List? record, Uint8List? parameterSets});
typedef _DecodeRun = ({
  List<FramePacket> packets,
  List<int> targets,
  Uint8List? configuration,
  _NalConfiguration? nalConfiguration,
});
