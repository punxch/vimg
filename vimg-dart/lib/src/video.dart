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
import 'grid.dart' show resizeToFit;
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
import 'quicktime_animation.dart';
import 'quicktime_raw.dart';
import 'quicktime_rpza.dart';
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

  String get _decodeCodec => _systems?.programCodec ?? codec;

  bool get usesReferencePictures => _mixedIsoCodecs
      ? _isoSections.any((section) => _usesReferences(section.codec))
      : _usesReferences(_decodeCodec);

  bool get scalesBeforeRgb =>
      usesReferencePictures ||
      (_mixedIsoCodecs
          ? _isoSections.any(
              (section) =>
                  section.codec == 'prores' ||
                  isQuickTimeRawCodec(section.codec),
            )
          : codec == 'prores' || (_iso != null && isQuickTimeRawCodec(codec)));

  void close() => _input.closeSync();

  late final _nalTimeline = _indexNalVideo();
  final _previewNalConfigurations = <FramePacket, _NalConfiguration>{};
  final _previewAv1Configurations = <FramePacket, Uint8List>{};
  late final _av1Timeline = _indexAv1();
  late final _mpegTimeline = _indexMpeg();
  late final _quickTimeDeltaTimeline = _indexQuickTimeDelta(codec);
  late final bool _mixedIsoCodecs = _hasMixedIsoCodecs();
  late final List<_IsoSection> _isoSections = _readIsoSections();
  late final Map<FramePacket, _IsoSection> _isoSectionByPacket = {
    for (final section in _isoSections)
      for (final packet in section.visible) packet: section,
  };
  final _quickTimeFormats = <MediaBox, QuickTimeRawFormat>{};
  final _quickTimeDescriptions = <FramePacket, MediaBox>{};

  QuickTimeRawFormat? _quickTimeFormat(FramePacket packet, String name) {
    final iso = _iso;
    if (iso == null || !isQuickTimeRawCodec(name)) return null;
    final description =
        _quickTimeDescriptions[packet] ??
        _isoSectionByPacket[packet]?.description;
    if (description == null)
      throw const FormatException('Unknown QuickTime video sample');
    return _quickTimeFormats.putIfAbsent(
      description,
      () => QuickTimeRawFormat(iso, description),
    );
  }

  bool _hasMixedIsoCodecs() {
    final iso = _iso;
    if (iso == null) return false;
    final track = iso.firstVideoTrack();
    final table = iso.sampleTable(iso.child(track, 'mdia'));
    final entries = iso.sampleDescriptions(table).iterator;
    if (!entries.moveNext()) return false;
    final first = iso.videoCodec(entries.current);
    while (entries.moveNext()) {
      if (iso.videoCodec(entries.current) != first) return true;
    }
    return false;
  }

  List<_IsoSection> _readIsoSections() {
    final iso = _iso!;
    final sections = <_IsoSection>[];
    for (final packet in isoFrames(
      iso,
      onDescription: (entry) {
        sections.add(
          _IsoSection(iso.videoCodec(entry), entry, sections.isNotEmpty),
        );
      },
      onSample: (packet, sync) => sections.last.samples.add((packet, sync)),
    )) {
      sections.last.visible.add(packet);
    }
    return sections;
  }

  _IndexedVideo _indexIsoSection(_IsoSection section) {
    final name = section.codec;
    if (name == 'qtrle' || name == 'rpza') {
      return _indexQuickTimeDelta(name, section: section);
    }
    if (name == 'av1') return _indexAv1(section: section);
    if (isMpegVideo(name)) return _indexMpeg(section: section);
    return _indexNalVideo(section: section);
  }

  _IndexedVideo _indexQuickTimeDelta(String name, {_IsoSection? section}) {
    final decodeOrder = <FramePacket>[];
    final index = <FramePacket, int>{};
    final gopStart = <int>[];
    final configurations = <int, _RunConfiguration>{};
    final sections = <int, int>{};
    var start = -1, sectionStart = 0;
    late Uint8List description;
    var rpzaBlocks = 0;
    final presentation =
        _containerPackets(
            false,
            section: section,
            onDescription: (entry) {
              _iso!.requireBytes(entry, 78);
              if (entry.end - entry.data > 1024 * 1024) {
                throw const FormatException(
                  'Oversized QuickTime video description',
                );
              }
              description = file.read(entry.data, entry.end - entry.data);
              if (name == 'rpza') {
                rpzaBlocks = QuickTimeRpzaDecoder(description).blockCount;
              }
              start = -1;
              sectionStart = decodeOrder.length;
            },
            onSample: (packet, sync) {
              final position = decodeOrder.length;
              final keyframe = name == 'rpza'
                  ? isRpzaKeyframe(_read(packet), rpzaBlocks)
                  : sync;
              if (keyframe) {
                start = position;
                configurations[start] = (bytes: description, nal: null);
                sections[start] = sectionStart;
              }
              index[packet] = position;
              decodeOrder.add(packet);
              gopStart.add(start);
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
    if (_mixedIsoCodecs) return _mixedIsoPackets(preview);
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
    if (codec == 'qtrle' || codec == 'rpza') {
      final indexed = _quickTimeDeltaTimeline;
      return indexed.timeline.presentation.where(
        (packet) =>
            !preview ||
            indexed.configurations.containsKey(indexed.timeline.index[packet]),
      );
    }
    final keyframes = preview && codec == 'vp8';
    final avi = _avi;
    _checkIndependentCodec(codec, preview: preview);
    if (avi != null) return avi.packets();
    if (_iso != null && isQuickTimeRawCodec(codec)) return _quickTimePackets();
    return _containerPackets(keyframes);
  }

  Iterable<FramePacket> _quickTimePackets() sync* {
    late MediaBox description;
    for (final packet in _containerPackets(
      false,
      onDescription: (entry) => description = entry,
    )) {
      _quickTimeDescriptions[packet] = description;
      yield packet;
    }
  }

  Iterable<FramePacket> _mixedIsoPackets(bool preview) sync* {
    final packets = <FramePacket>[];
    for (final section in _isoSections) {
      final name = section.codec;
      if (_usesReferences(name)) {
        final indexed = section.indexed ??= _indexIsoSection(section);
        packets.addAll(
          indexed.timeline.presentation.where((packet) {
            if (!preview) return true;
            return indexed.configurations.containsKey(
              indexed.timeline.index[packet],
            );
          }),
        );
      } else {
        _checkIndependentCodec(name, preview: preview);
        packets.addAll(section.packets(keyframes: preview && name == 'vp8'));
      }
    }
    // A fragment or chunk can begin in decode order before the preceding
    // section's last composition timestamp.
    final ordered = packets.indexed.toList()
      ..sort((a, b) {
        final byTime = a.$2.seconds.compareTo(b.$2.seconds);
        return byTime == 0 ? a.$1.compareTo(b.$1) : byTime;
      });
    yield* ordered.map((entry) => entry.$2);
  }

  void _checkIndependentCodec(String name, {bool preview = false}) {
    if (name == 'mjpeg' ||
        name == 'png' ||
        name == 'prores' ||
        (_iso != null && isQuickTimeRawCodec(name)) ||
        (preview && name == 'vp8') ||
        (name == 'rawvideo' && _avi?.supportsBitmap == true)) {
      return;
    }
    throw UnsupportedError('Pure Dart decoding for $name is unavailable');
  }

  Iterable<FramePacket> _containerPackets(
    bool keyframes, {
    FrameVisitor? onSample,
    void Function(MediaBox)? onDescription,
    _IsoSection? section,
  }) {
    if (section != null) {
      onDescription?.call(section.description);
      return section.packets(keyframes: keyframes, onSample: onSample);
    }
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

  _IndexedVideo _indexAv1({_IsoSection? section}) {
    var configuration = _iso == null ? _av1Configuration() : Uint8List(0);
    var units = Av1AccessUnits()..configure(configuration);
    final decodeOrder = <FramePacket>[], startPositions = <int>[];
    final shown = <FramePacket>{};
    final index = <FramePacket, int>{};
    final configurations = <int, _RunConfiguration>{};
    var start = -1;
    var newDescription = false;
    final presentation =
        _containerPackets(
          false,
          section: section,
          onDescription: (entry) {
            newDescription = section?.restart == true || decodeOrder.isNotEmpty;
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
                configurations[start] = (
                  bytes: units.sequenceConfiguration ?? configuration,
                  nal: null,
                );
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
      sections: const {},
    );
  }

  /// A sample may introduce parameters used only by a later picture.
  /// Keep the parameters already available before each random-access sample
  /// so the decoder can then read that sample's own NALs in their original order.
  Iterable<FramePacket> _nalPackets({
    bool preview = false,
    void Function(FramePacket, int?, bool, _NalConfiguration?, bool)? onSample,
    _IsoSection? section,
  }) sync* {
    final systems = _systems;
    final name = section?.codec ?? codec;
    final isHevc = name == 'hevc';
    Uint8List? record;
    HevcConfiguration? hevc;
    AvcConfiguration? avc;
    var parameters = NalParameterSets();
    var newDescription = false, hasPicture = false;
    void configure([MediaBox? description]) {
      record = _configuration(name, description);
      if (isHevc) {
        hevc = HevcConfiguration(record!);
      } else {
        avc = AvcConfiguration(record!);
      }
      parameters = NalParameterSets(
        lengthBytes: hevc?.lengthBytes ?? avc!.lengthBytes,
      );
      newDescription = hasPicture || section?.restart == true;
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
      section: section,
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

  _IndexedVideo _indexNalVideo({_IsoSection? section}) {
    final isHevc = (section?.codec ?? codec) == 'hevc';
    final decodeOrder = <FramePacket>[];
    final index = <FramePacket, int>{};
    final gopStart = <int>[];
    final configurations = <int, _RunConfiguration>{};
    final sections = <int, int>{};
    var start = -1, previous = -1, sectionStart = 0;
    final presentation = _nalPackets(
      section: section,
      onSample: (packet, type, randomAccess, configuration, newDescription) {
        final position = decodeOrder.length;
        if (randomAccess) {
          // RASL pictures following a CRA can still refer across it.
          previous = isHevc && type == 21 && !newDescription ? start : -1;
          start = position;
          if (newDescription) sectionStart = start;
          configurations[start] = (bytes: null, nal: configuration!);
          sections[start] = sectionStart;
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

  _IndexedVideo _indexMpeg({_IsoSection? section}) {
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
    final index = <FramePacket, int>{};
    final configurations = <int, _RunConfiguration>{};
    final sections = <int, int>{};
    var start = -1, bStart = -1, sectionStart = 0;
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
            configurations[decodeOrder.length] = (
              bytes: headers.configuration(),
              nal: null,
            );
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
            section: section,
            onDescription: (entry) {
              configure(_iso!.mpegVideoConfiguration(description: entry));
              sectionStart = decodeOrder.length;
              start = bStart = -1;
            },
            onSample: (packet, _) {
              final position = decodeOrder.length;
              final picture = pictureInfo(packet);
              if ((sectionStart > 0 || section?.restart == true) &&
                  position == sectionStart &&
                  picture.type != 1) {
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
                  sections[start] = sectionStart;
                  if (systems != null) {
                    configurations[position] = (
                      bytes: systems.configurationAt(packet)!,
                      nal: null,
                    );
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
    if (_mixedIsoCodecs) {
      final bySection = <_IsoSection, List<FramePacket>>{};
      for (final packet in selected) {
        final section = _isoSectionByPacket[packet];
        if (section == null)
          throw const FormatException('Unknown video packet');
        bySection.putIfAbsent(section, () => []).add(packet);
      }
      for (final entry in bySection.entries) {
        final section = entry.key;
        final name = section.codec;
        final indexed = _usesReferences(name)
            ? section.indexed ??= _indexIsoSection(section)
            : null;
        yield* _runs(entry.value, name, indexed);
      }
      return;
    }
    final name = _decodeCodec;
    final indexed = switch (name) {
      'av1' => _av1Timeline,
      'h264' || 'hevc' => _nalTimeline,
      'qtrle' || 'rpza' => _quickTimeDeltaTimeline,
      _ when isMpegVideo(name) => _mpegTimeline,
      _ => null,
    };
    yield* _runs(selected, name, indexed);
  }

  Iterable<_DecodeRun> _runs(
    Iterable<FramePacket> selected,
    String name,
    _IndexedVideo? indexed,
  ) sync* {
    if (indexed == null) {
      for (final packet in selected) {
        yield (
          codec: name,
          packets: [packet],
          targets: const [0],
          configuration: null,
          rawFormat: _quickTimeFormat(packet, name),
        );
      }
      return;
    }
    final av1 = name == 'av1';
    final (:timeline, :configurations, :sections) = indexed;
    final targets = {
      for (final packet in selected)
        timeline.index[packet] ??
            (throw FormatException('Unknown ${av1 ? 'AV1 ' : ''}video packet')),
    }.toList()..sort();
    var start = -1, end = -1;
    var wanted = <int>[];
    _DecodeRun run() => (
      codec: name,
      packets: timeline.decodeOrder.sublist(start, end + 1),
      targets: wanted,
      configuration: configurations[start]!,
      rawFormat: null,
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
    final name = run.codec;
    if (!_usesReferences(name)) {
      final packet = run.packets.single;
      final _RenderPicture render;
      if (run.rawFormat case final raw?) {
        final bytes = _read(packet);
        if (raw.tag == 'raw ') {
          render = ({scaler}) => raw.decode(
            bytes,
            scaler: scaler,
            includeAlpha: scaler?.width == null && scaler?.height == null,
          );
        } else {
          final picture = raw.components(
            bytes,
            includeAlpha:
                raw.hasAlpha &&
                (includeOriginal ||
                    (scaler?.width == null && scaler?.height == null)),
          );
          render = ({scaler}) => picture.rgb(
            scaler: scaler,
            includeAlpha: scaler?.width == null && scaler?.height == null,
          );
        }
      } else if (name == 'prores') {
        final keepAlpha =
            includeOriginal ||
            (scaler?.width == null && scaler?.height == null);
        final picture = _proRes(packet, preserveAlpha: keepAlpha);
        render = ({scaler}) => picture.rgb(
          scaler: scaler,
          includeAlpha: scaler?.width == null && scaler?.height == null,
        );
      } else {
        final source = _decodeIndependent(packet, name);
        render = ({scaler}) => _renderRgb(source, scaler);
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
          name == 'av1'
              ? 'AV1 sample has no display picture'
              : 'Invalid $name video frame',
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
    final configuration = run.configuration!;
    switch (run.codec) {
      case 'qtrle':
        final decoder = QuickTimeAnimationDecoder(configuration.bytes!);
        return (bytes, selected) {
          decoder.advance(bytes);
          if (!selected) return null;
          final source = decoder.rgb();
          return ({scaler}) => _renderRgb(source, scaler);
        };
      case 'rpza':
        final decoder = QuickTimeRpzaDecoder(configuration.bytes!);
        return (bytes, selected) {
          decoder.advance(bytes);
          if (!selected) return null;
          final source = decoder.rgb();
          return ({scaler}) => _renderRgb(source, scaler);
        };
      case 'av1':
        final units = Av1AccessUnits()..configure(configuration.bytes!);
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
          _hevcDecoderConfig(configuration.nal!),
        );
        return (bytes, selected) {
          final picture = decoder.decode(bytes);
          return selected ? picture?.rgb : null;
        };
      case 'mpeg1video' || 'mpeg2video':
        final decoder = MpegStreamDecoder(configuration.bytes);
        return (bytes, selected) {
          if (selected) return decoder.decode(bytes).rgb;
          decoder.advance(bytes);
          return null;
        };
      default:
        final decoder = H264StreamDecoder(
          _avcDecoderConfig(configuration.nal!),
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

  image.Image _renderRgb(image.Image source, YuvImageScaler? scaler) {
    if (scaler == null) return source;
    final frame =
        source.hasAlpha && (scaler.width != null || scaler.height != null)
        ? _rgb(source)
        : source;
    return scaler.filters != null
        ? scaler.filterRgb(frame)
        : resizeToFit(frame, width: scaler.width, height: scaler.height);
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
    if (_mixedIsoCodecs) {
      final section = _isoSectionByPacket[packet];
      if (section == null) throw const FormatException('Unknown video packet');
      if (!_usesReferences(section.codec)) {
        return _decodeIndependent(packet, section.codec, preview: preview);
      }
      final frame = decodeSelected([packet]).single.frame;
      return preview && section.codec == 'qtrle' ? _rgb(frame) : frame;
    }
    if (codec == 'qtrle' || codec == 'rpza') {
      final frame = decodeSelected([packet]).single.frame;
      return preview && frame.hasAlpha ? _rgb(frame) : frame;
    }
    if (usesReferencePictures &&
        (_systems != null ||
            !preview ||
            isMpegVideo(codec) ||
            (codec == 'av1'
                ? !_previewAv1Configurations.containsKey(packet)
                : !_previewNalConfigurations.containsKey(packet)))) {
      return decodeSelected([packet]).single.frame;
    }
    if (codec == 'h264') {
      final config = _avcDecoderConfig(_previewNalConfigurations[packet]!);
      return H264IdrDecoder(config).decode(_read(packet))?.rgb() ??
          decodeSelected([packet]).single.frame;
    }
    if (codec == 'hevc') {
      final config = _hevcDecoderConfig(_previewNalConfigurations[packet]!);
      return HevcIntraDecoder(config).decode(_read(packet))?.rgb() ??
          decodeSelected([packet]).single.frame;
    }
    if (codec == 'av1') {
      final decoder = Av1AccessUnits()
        ..configure(_previewAv1Configurations[packet]!);
      for (final frame in decoder.readSample(_read(packet))) {
        if (frame.header.type.intra && frame.shown) {
          return decodeAv1IntraImage(frame);
        }
      }
      throw const FormatException('No independently decodable AV1 picture');
    }
    return _decodeIndependent(packet, codec, preview: preview);
  }

  image.Image _decodeIndependent(
    FramePacket packet,
    String name, {
    bool preview = false,
  }) {
    if (name == 'prores') {
      return _proRes(packet, preserveAlpha: !preview).rgb();
    }
    final bytes = _read(packet);
    if (_quickTimeFormat(packet, name) case final raw?) {
      return raw.decode(bytes, includeAlpha: !preview);
    }
    final frame = switch (name) {
      'mjpeg' => image.decodeJpg(bytes),
      'png' => image.decodePng(bytes),
      'vp8' => _vp8Keyframe(bytes),
      'rawvideo' => _avi?.decodeBitmap(bytes),
      _ => null,
    };
    if (frame == null) throw FormatException('Invalid $name video frame');
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
typedef _RunConfiguration = ({Uint8List? bytes, _NalConfiguration? nal});
typedef _IndexedVideo = ({
  _VideoTimeline timeline,
  Map<int, _RunConfiguration> configurations,
  Map<int, int> sections,
});
typedef _DecodeRun = ({
  String codec,
  List<FramePacket> packets,
  List<int> targets,
  _RunConfiguration? configuration,
  QuickTimeRawFormat? rawFormat,
});

bool _usesReferences(String codec) =>
    codec == 'h264' ||
    codec == 'hevc' ||
    codec == 'av1' ||
    codec == 'qtrle' ||
    codec == 'rpza' ||
    isMpegVideo(codec);

final class _IsoSection {
  _IsoSection(this.codec, this.description, this.restart);

  final String codec;
  final MediaBox description;
  final bool restart;
  final samples = <(FramePacket, bool)>[];
  final visible = <FramePacket>{};
  _IndexedVideo? indexed;

  Iterable<FramePacket> packets({
    bool keyframes = false,
    FrameVisitor? onSample,
  }) sync* {
    for (final (packet, sync) in samples) {
      onSample?.call(packet, sync);
      if ((!keyframes || sync) && visible.contains(packet)) yield packet;
    }
  }
}
