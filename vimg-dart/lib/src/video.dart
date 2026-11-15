import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as image;

import 'avi.dart';
import 'avi_nal.dart';
import 'av1/access_units.dart';
import 'av1/frame_header.dart';
import 'av1/picture_decoder.dart';
import 'binary_file.dart';
import 'capture_timeline.dart';
import 'cinepak.dart';
import 'ffv1.dart';
import 'frame_packet.dart';
import 'grid.dart' show resizeToFit;
import 'huffyuv.dart' show isHuffYuvCodec;
import 'h264/access_unit.dart';
import 'h264/idr_picture.dart';
import 'hevc/access_unit.dart';
import 'hevc/decode_picture.dart';
import 'hevc/nal.dart';
import 'iso_media.dart';
import 'ivf.dart';
import 'matroska.dart';
import 'matroska_frames.dart';
import 'metadata.dart';
import 'mpeg12/decode.dart';
import 'mpeg12/syntax.dart';
import 'mpeg_systems.dart';
import 'msrle.dart';
import 'msvideo1.dart';
import 'nal_parameter_sets.dart';
import 'prores.dart';
import 'quicktime_animation.dart';
import 'quicktime_raw.dart';
import 'quicktime_rpza.dart';
import 'quicktime_smc.dart';
import 'video_configuration.dart';
import 'vp8/decoder.dart';
import 'vp9/bitstream.dart';
import 'vp9/intra.dart';
import 'yuv_image.dart';

part 'video_workers.dart';
part 'video_vp8_alpha.dart';

typedef _SelectedFrame = ({
  FramePacket packet,
  CaptureFrame capture,
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
      } else if (signature == 0x444b4946) {
        _ivf = Ivf(file);
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
  Ivf? _ivf;
  MpegSystemsVideo? _systems;

  late final VideoMetadata metadata =
      _matroska?.metadata() ??
      _avi?.metadata() ??
      _ivf?.metadata() ??
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
          : codec == 'prores' ||
                isHuffYuvCodec(codec) ||
                (codec == 'rawvideo' && _rawVideoFormat != null) ||
                (_iso != null && isQuickTimeRawCodec(codec)));

  void close() => _input.closeSync();

  late final _matroskaPresentation = _matroska?.videoPresentation();
  late final _rawVideoFormat =
      _avi?.rawFormat ??
      (_matroska == null ? null : matroskaRawVideoConfiguration(_matroska!));
  late final _orientation =
      _iso?.videoOrientation() ?? _matroskaPresentation?.orientation;
  late final _crop = _matroskaPresentation?.crop;
  bool get _hasPresentationTransform => _orientation != null || _crop != null;
  late final _previewScaler = _presentationScaler(null);
  late final _captureScalers = Expando<Map<double?, YuvImageScaler>>();

  YuvImageScaler? _presentationScaler(
    YuvImageScaler? scaler, {
    double? aspect,
  }) {
    aspect ??= _matroskaPresentation?.sampleAspect;
    if (!_hasPresentationTransform &&
        (aspect == null || scaler?.filters == null)) {
      return scaler;
    }
    if (scaler == null) {
      return YuvImageScaler.presentation(
        null,
        crop: _crop,
        orientation: _orientation,
      );
    }
    final byAspect = _captureScalers[scaler] ??= {};
    return byAspect[aspect] ??= YuvImageScaler.presentation(
      scaler,
      crop: _crop,
      orientation: _orientation,
      sampleAspect: aspect,
    );
  }

  late final _nalTimeline = _indexNalVideo();
  late final _aviNal = _avi != null && (codec == 'h264' || codec == 'hevc')
      ? AviNal(_avi!, codec)
      : null;
  final _previewNalConfigurations = <FramePacket, _NalConfiguration>{};
  final _avcFieldPairKeys = <FramePacket>{};
  final _previewAv1Configurations = <FramePacket, Uint8List>{};
  late final _av1Timeline = _indexAv1();
  late final _mpegTimeline = _indexMpeg();
  late final _statefulTimeline = _indexStatefulPictures(codec);
  final _vp9PreviewPackets = <FramePacket>{};
  late final _huffYuv =
      _avi?.huffYuvDecoder() ??
      (_matroska == null
          ? null
          : matroskaHuffYuvConfiguration(_matroska!, codec)) ??
      (throw const FormatException('Missing HuffYUV configuration'));
  late final _matroskaVideo1 = _matroska == null
      ? null
      : matroskaVideo1Configuration(_matroska!);
  late final bool _mixedIsoCodecs = _hasMixedIsoCodecs();
  late final List<_IsoSection> _isoSections = _readIsoSections();
  late final Map<FramePacket, _IsoSection> _isoSectionByPacket = {
    for (final section in _isoSections)
      for (final packet in section.visible) packet: section,
  };
  final _quickTimeFormats = <MediaBox, QuickTimeRawFormat>{};
  final _isoDescriptionsByPacket = <FramePacket, MediaBox>{};
  final _isoAspects = <FramePacket, double>{};
  final _descriptionAspects = <MediaBox, double?>{};
  late final _isoDescriptions = _readIsoDescriptions();

  double? _descriptionAspect(MediaBox entry) => _descriptionAspects.putIfAbsent(
    entry,
    () => _iso!.visualSampleAspect(entry),
  );

  QuickTimeRawFormat? _quickTimeFormat(FramePacket packet, String name) {
    final iso = _iso;
    if (iso == null || !isQuickTimeRawCodec(name)) return null;
    final description =
        _isoDescriptionsByPacket[packet] ??
        _isoSectionByPacket[packet]?.description;
    if (description == null)
      throw const FormatException('Unknown QuickTime video sample');
    return _quickTimeFormats.putIfAbsent(
      description,
      () => QuickTimeRawFormat(iso, description),
    );
  }

  List<MediaBox> _readIsoDescriptions() {
    final iso = _iso;
    if (iso == null) return const [];
    final track = iso.firstVideoTrack();
    final table = iso.sampleTable(iso.child(track, 'mdia'));
    return iso.sampleDescriptions(table).toList();
  }

  bool _hasMixedIsoCodecs() =>
      _isoDescriptions.map((entry) => _iso!.videoCodec(entry)).toSet().length >
      1;

  late final _commonIsoAspect = _isoDescriptions.length == 1
      ? _descriptionAspect(_isoDescriptions.single)
      : null;

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
    if (_hasStatefulFrames(name)) {
      return _indexStatefulPictures(name, section: section);
    }
    if (name == 'av1') return _indexAv1(section: section);
    if (isMpegVideo(name)) return _indexMpeg(section: section);
    return _indexNalVideo(section: section);
  }

  _Vp8AlphaIndex? _vp8Alpha;

  _IndexedVideo _indexStatefulPictures(String name, {_IsoSection? section}) {
    final alpha = _matroska != null && name == 'vp8'
        ? _Vp8AlphaIndex(file)
        : null;
    final decodeOrder = <FramePacket>[];
    final index = <FramePacket, int>{};
    final hidden = <FramePacket>{};
    final gopStart = <int>[];
    final configurations = <int, _RunConfiguration>{};
    final sections = <int, int>{};
    var start = -1, sectionStart = 0;
    Uint8List? description;
    var rpzaBlocks = 0;
    SmcPictureOrder? smc;
    CinepakPictureOrder? cinepak;
    void setCinepakDescription(Uint8List entry) {
      final format = CinepakDecoder(entry);
      cinepak = CinepakPictureOrder(format.width, format.height);
    }

    final avi = _avi;
    final rle = avi?.rleFormat;
    MediaBox? ffv1Entry;
    final video1 = name == 'msvideo1'
        ? avi?.video1Format ?? _matroskaVideo1?.format
        : null;
    bool isRleKeyframe(FramePacket packet, int position) {
      final raw = avi!.isUncompressedRle(packet);
      final complete = raw || rle!.isComplete(_read(packet));
      // The first picture can leave pixels at their initial palette index 0.
      return complete || position == 0;
    }

    if (name == 'ffv1') {
      description =
          avi?.videoPrivateData() ??
          (_matroska == null
              ? null
              : matroskaVideoConfiguration(_matroska!, name));
    }
    if (avi?.cinepakDescription case final entry?) {
      description = entry;
      setCinepakDescription(entry);
    }
    final presentation =
        _containerPackets(
              false,
              section: section,
              onAlpha: alpha?.add,
              onDescription: (entry) {
                _iso!.requireBytes(entry, 78);
                if (name == 'ffv1') {
                  ffv1Entry = entry;
                  description = isoVideoConfiguration(
                    _iso!,
                    name,
                    description: entry,
                  );
                } else if (name != 'vp8' && name != 'vp9') {
                  if (entry.end - entry.data > 1024 * 1024) {
                    throw const FormatException(
                      'Oversized QuickTime video description',
                    );
                  }
                  final bytes = file.read(entry.data, entry.end - entry.data);
                  description = bytes;
                  if (name == 'rpza') {
                    rpzaBlocks = QuickTimeRpzaDecoder(bytes).blockCount;
                  } else if (name == 'smc') {
                    smc = SmcPictureOrder(
                      QuickTimeSmcDecoder(bytes).blockCount,
                    );
                  } else if (name == 'cinepak') {
                    setCinepakDescription(bytes);
                  }
                }
                start = -1;
                sectionStart = decodeOrder.length;
              },
              onSample: (packet, sync) {
                final position = decodeOrder.length;
                final vp8 = name == 'vp8'
                    ? vp8FrameTag(_readPrefix(packet, 3))
                    : null;
                final vp9 = name == 'vp9' ? _vp9Tag(packet) : null;
                if (vp8?.shown == false || vp9?.shown == false) {
                  hidden.add(packet);
                }
                if (vp9?.preview != null) _vp9PreviewPackets.add(packet);
                final anchor =
                    smc?.anchor(_read(packet), position) ??
                    cinepak?.anchor(_read(packet), position);
                final keyframe =
                    vp8?.key ??
                    vp9?.key ??
                    (anchor != null
                        ? anchor == position
                        : name == 'ffv1'
                        ? isFfv1Keyframe(_readPrefix(packet, 2))
                        : name == 'rpza'
                        ? isRpzaKeyframe(_read(packet), rpzaBlocks)
                        : rle != null
                        ? isRleKeyframe(packet, position)
                        : video1 != null
                        ? video1.isComplete(_read(packet)) || position == 0
                        : sync);
                if (keyframe) {
                  start = position;
                  if (ffv1Entry case final entry?) {
                    _isoDescriptionsByPacket[packet] = entry;
                  }
                  configurations[start] = (bytes: description, nal: null);
                  sections[start] = sectionStart;
                }
                index[packet] = position;
                decodeOrder.add(packet);
                gopStart.add(anchor ?? start);
              },
            )
            .where(
              (packet) =>
                  !hidden.contains(packet) && gopStart[index[packet]!] >= 0,
            )
            .toList()
          ..sort((a, b) {
            final byTime = a.seconds.compareTo(b.seconds);
            return byTime == 0 ? index[a]!.compareTo(index[b]!) : byTime;
          });
    if (alpha != null) _vp8Alpha = alpha;
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
          ? _orderedIfNeeded(_nalPackets(preview: true))
          : _nalTimeline.timeline.presentation;
    }
    if (codec == 'av1') {
      return preview
          ? _orderedIfNeeded(_av1PreviewPackets())
          : _av1Timeline.timeline.presentation;
    }
    if (_hasStatefulFrames(codec)) {
      final indexed = _statefulTimeline;
      return indexed.timeline.presentation.where(
        (packet) =>
            !preview ||
            (codec == 'vp9'
                ? _vp9PreviewPackets.contains(packet)
                : indexed.configurations.containsKey(
                    indexed.timeline.index[packet],
                  )),
      );
    }
    final avi = _avi;
    _checkIndependentCodec(codec);
    if (avi != null) return avi.packets();
    return _orderedIfNeeded(
      _iso != null && isQuickTimeRawCodec(codec)
          ? _quickTimePackets()
          : _containerPackets(false),
    );
  }

  Iterable<FramePacket> _orderedIfNeeded(Iterable<FramePacket> packets) =>
      _iso?.hasOverlappingVideoFragments == true ||
          _ivf?.outOfOrder == true ||
          _aviNal != null
      ? _presentationOrder(packets)
      : packets;

  Iterable<FramePacket> _quickTimePackets() sync* {
    late MediaBox description;
    for (final packet in _containerPackets(
      false,
      onDescription: (entry) => description = entry,
    )) {
      _isoDescriptionsByPacket[packet] = description;
      yield packet;
    }
  }

  Iterable<FramePacket> _mixedIsoPackets(bool preview) sync* {
    final packets = <FramePacket>[];
    for (final section in _isoSections) {
      if (section.visible.isEmpty) continue;
      final name = section.codec;
      if (_usesReferences(name)) {
        final indexed = section.indexed ??= _indexIsoSection(section);
        packets.addAll(
          indexed.timeline.presentation.where((packet) {
            if (!preview) return true;
            if (name == 'vp9') return _vp9PreviewPackets.contains(packet);
            return _avcFieldPairKeys.contains(packet) ||
                indexed.configurations.containsKey(
                  indexed.timeline.index[packet],
                );
          }),
        );
      } else {
        _checkIndependentCodec(name);
        packets.addAll(section.packets());
      }
    }
    // A fragment or chunk can begin in decode order before the preceding
    // section's last composition timestamp.
    yield* _presentationOrder(packets);
  }

  Iterable<FramePacket> _presentationOrder(Iterable<FramePacket> packets) {
    final ordered = packets.indexed.toList()
      ..sort((a, b) {
        final byTime = a.$2.seconds.compareTo(b.$2.seconds);
        return byTime == 0 ? a.$1.compareTo(b.$1) : byTime;
      });
    return ordered.map((entry) => entry.$2);
  }

  void _checkIndependentCodec(String name) {
    if (name == 'mjpeg' ||
        name == 'png' ||
        name == 'prores' ||
        isHuffYuvCodec(name) ||
        (_iso != null && isQuickTimeRawCodec(name)) ||
        (name == 'rawvideo' &&
            (_avi?.supportsBitmap == true || _rawVideoFormat != null))) {
      return;
    }
    throw UnsupportedError('Pure Dart decoding for $name is unavailable');
  }

  Iterable<FramePacket> _containerPackets(
    bool keyframes, {
    FrameVisitor? onSample,
    MatroskaAlphaVisitor? onAlpha,
    void Function(MediaBox)? onDescription,
    _IsoSection? section,
  }) {
    if (section != null) {
      onDescription?.call(section.description);
      return section.packets(keyframes: keyframes, onSample: onSample);
    }
    final systems = _systems;
    if (systems != null) return systems.packets(keyframes, onSample: onSample);
    if (_avi case final avi?) return avi.packets(onSample: onSample);
    if (_ivf case final ivf?) return ivf.packets(keyframes, onSample: onSample);
    final matroska = _matroska;
    if (matroska != null) {
      return matroskaFrames(
        matroska,
        keyframes: keyframes,
        onSample: onSample,
        onAlpha: onAlpha,
      );
    }
    final iso = _iso!;
    final changingAspect = _isoDescriptions.length > 1;
    double? aspect;
    return isoFrames(
      iso,
      keyframes: keyframes,
      onSample: !changingAspect
          ? onSample
          : (packet, sync) {
              if (aspect != null) _isoAspects[packet] = aspect!;
              onSample?.call(packet, sync);
            },
      onDescription: (entry) {
        if (iso.videoCodec(entry) != codec) {
          throw const FormatException(
            'ISO media video codec changes within a track',
          );
        }
        if (changingAspect) aspect = _descriptionAspect(entry);
        onDescription?.call(entry);
      },
    );
  }

  Iterable<FramePacket> _av1PreviewPackets() sync* {
    if (_ivf case final ivf?) {
      final units = Av1AccessUnits();
      for (final packet in ivf.packets(false)) {
        Uint8List? configuration;
        for (final (i, frame) in units.readSample(_read(packet)).indexed) {
          if (i == 0 && _av1RandomAccess(frame)) {
            configuration = units.sequenceConfiguration;
          }
        }
        if (configuration != null) {
          _previewAv1Configurations[packet] = configuration;
          yield packet;
        }
      }
      return;
    }
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
              if (first && _av1RandomAccess(frame)) {
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
    if (_aviNal case final avi?) {
      for (final frame in avi.frames) {
        final packet = frame.packet;
        final _NalConfiguration? configuration = frame.randomAccess
            ? (record: avi.record, parameterSets: frame.parameters)
            : null;
        onSample?.call(
          packet,
          frame.type,
          frame.randomAccess,
          configuration,
          false,
        );
        if (!frame.shown || preview && !frame.keyframe) continue;
        if (preview && configuration != null)
          _previewNalConfigurations[packet] = configuration;
        yield packet;
      }
      return;
    }
    final systems = _systems;
    final name = section?.codec ?? codec;
    final isHevc = name == 'hevc';
    Uint8List? record;
    HevcConfiguration? hevc;
    AvcConfiguration? avc;
    var parameters = NalParameterSets();
    var newDescription = false, hasPicture = false;
    ({FramePacket packet, H264FieldKey field, bool keyframe})? pendingField;
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
      pendingField = null;
    }

    if (_matroska != null) configure();
    final encodedFrames = _matroska?.hasEncodedFrames ?? false;

    int? type;
    var keyframe = false;
    FramePacket? display;
    var fieldPair = false;
    _NalConfiguration? configuration;
    for (final _ in _containerPackets(
      false,
      section: section,
      onDescription: configure,
      onSample: (packet, sync) {
        final before = parameters.snapshot();
        final restored = encodedFrames ? _read(packet) : null;
        final offset = restored == null ? packet.offset : 0;
        final size = restored?.length ?? packet.size;
        final read = restored == null
            ? file.read
            : (int start, int length) =>
                  Uint8List.sublistView(restored, start, start + length);
        final unsigned = restored == null
            ? file.unsigned
            : (int start, int length) => readBigEndian(read(start, length));
        void parameterSet(int start, int length) {
          final nal = read(start, length);
          final key = hevc == null
              ? avc!.store(nal)
              : hevc!.store(HevcNal(nal));
          parameters.update(key!, nal);
        }

        final header = hevc?.pictureHeader(
          offset,
          size,
          unsigned,
          onParameterSet: parameterSet,
        );
        final avcSample = avc?.sampleHeader(
          offset,
          size,
          unsigned,
          readBytes: read,
          onParameterSet: parameterSet,
        );
        type = systems?.nalType(packet) ?? header?.type ?? avcSample?.type;
        var random = systems != null
            ? sync
            : isHevc
            ? header?.randomAccess == true
            : sync && type == 5;
        keyframe = sync && random;
        display = packet;
        fieldPair = false;
        final field = avcSample?.field;
        if (field != null) {
          final previous = pendingField;
          if (previous != null &&
              complementaryH264Fields(previous.field, field)) {
            final paired = _avcFieldPacket(previous.packet, packet);
            display = paired;
            fieldPair = true;
            keyframe = previous.keyframe;
            random = false; // decoding starts with the first field
            pendingField = null;
            if (keyframe) _avcFieldPairKeys.add(paired);
            if (section != null) _isoSectionByPacket[paired] = section;
            if (_isoAspects[packet] case final aspect?)
              _isoAspects[paired] = aspect;
          } else {
            pendingField = (packet: packet, field: field, keyframe: keyframe);
            display = null;
          }
        } else if (type != null) {
          pendingField = null;
        }
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
          onSample?.call(
            display ?? packet,
            type,
            random,
            configuration,
            newDescription,
          );
          newDescription = false;
          hasPicture = true;
        } else {
          onSample?.call(packet, type, random, configuration, false);
        }
      },
    )) {
      final packet = display;
      if (packet == null) continue;
      if (preview) {
        if (!keyframe) continue;
        if (!fieldPair) _previewNalConfigurations[packet] = configuration!;
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
      _ when _hasStatefulFrames(name) => _statefulTimeline,
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
          vp8Alpha: null,
          sampleAspect: _commonIsoAspect,
          sampleAspects: _captureAspects([packet]),
          aviPalettes: _avi?.hasPalette == true
              ? {0: _avi!.paletteFor(packet)!}
              : null,
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
    _DecodeRun run() {
      final packets = timeline.decodeOrder.sublist(start, end + 1);
      return (
        codec: name,
        packets: packets,
        targets: wanted,
        configuration: configurations[start]!,
        rawFormat: null,
        vp8Alpha: name == 'vp8' ? _vp8Alpha?.forRun(packets) : null,
        sampleAspect: _commonIsoAspect,
        sampleAspects: _captureAspects(
          wanted.map((i) => timeline.decodeOrder[start + i]),
        ),
        aviPalettes: _avi?.hasPalette == true
            ? {
                for (final i in wanted)
                  i: _avi!.paletteFor(timeline.decodeOrder[start + i])!,
              }
            : null,
      );
    }

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

  Map<FramePacket, double>? _captureAspects(Iterable<FramePacket> packets) {
    if (_isoDescriptions.length <= 1) return null;
    final result = <FramePacket, double>{};
    for (final packet in packets) {
      final description = _mixedIsoCodecs
          ? _isoSectionByPacket[packet]?.description
          : null;
      final aspect = description == null
          ? _isoAspects[packet]
          : _descriptionAspect(description);
      if (aspect != null) result[packet] = aspect;
    }
    return result.isEmpty ? null : result;
  }

  Iterable<_SelectedFrame> _decodeRun(
    _DecodeRun run,
    YuvImageScaler? requestedScaler,
    bool includeOriginal, {
    Map<FramePacket, Set<CaptureFrame>>? captures,
  }) sync* {
    YuvImageScaler? scalerFor(FramePacket packet) => requestedScaler == null
        ? _previewScaler
        : _presentationScaler(
            requestedScaler,
            aspect: run.sampleAspects?[packet] ?? run.sampleAspect,
          );
    Iterable<_SelectedFrame> renderCaptures(
      FramePacket packet,
      _RenderPicture render,
      YuvImageScaler? scaler,
    ) sync* {
      final unscaled = scaler?.unscaled;
      for (final capture in captures?[packet] ?? [CaptureFrame(packet)]) {
        image.Image renderAt(YuvImageScaler? target) =>
            target == null || capture.positions.isEmpty
            ? render(scaler: target)
            : target.renderCapture(
                capture.positions,
                () => render(scaler: target),
              );
        final frame = renderAt(scaler);
        yield (
          packet: packet,
          capture: capture,
          frame: frame,
          original: !includeOriginal
              ? null
              : identical(unscaled, scaler)
              ? frame
              : renderAt(unscaled),
        );
      }
    }

    final name = run.codec;
    if (!_usesReferences(name)) {
      final packet = run.packets.single;
      final scaler = scalerFor(packet);
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
      } else if (name == 'rawvideo' && _rawVideoFormat != null) {
        final picture = _rawVideoFormat.decode(
          _read(packet),
          includeAlpha:
              includeOriginal ||
              (scaler?.width == null && scaler?.height == null),
        );
        render = ({scaler}) => picture.rgb(
          scaler: scaler,
          includeAlpha: scaler?.width == null && scaler?.height == null,
        );
      } else if (isHuffYuvCodec(name)) {
        final picture = _huffYuv.decode(_read(packet));
        render = ({scaler}) => picture.rgb(
          scaler: scaler,
          includeAlpha: scaler?.width == null && scaler?.height == null,
        );
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
        final source = _decodeIndependent(
          packet,
          name,
          palette: run.aviPalettes?[0],
        );
        render = ({scaler}) => _renderRgb(source, scaler);
      }
      yield* renderCaptures(packet, render, scaler);
      return;
    }
    final readPicture = _pictureReader(run);
    var target = 0;
    for (final (i, packet) in run.packets.indexed) {
      final selected = i == run.targets[target];
      final render = readPicture(packet, selected, run.aviPalettes?[i]);
      if (!selected) continue;
      if (render == null) {
        throw FormatException(
          name == 'av1'
              ? 'AV1 sample has no display picture'
              : 'Invalid $name video frame',
        );
      }
      yield* renderCaptures(packet, render, scalerFor(packet));
      target++;
    }
  }

  _RenderPicture? Function(FramePacket, bool, List<int>?) _pictureReader(
    _DecodeRun run,
  ) {
    final configuration = run.configuration!;
    switch (run.codec) {
      case 'vp9':
        final decoder = Vp9Decoder();
        return (packet, selected, _) {
          final picture = decoder.decodePacket(_read(packet));
          if (!selected || picture == null) return null;
          return picture.rgb;
        };
      case 'vp8':
        final decoder = Vp8Decoder();
        final alpha = run.vp8Alpha;
        final opacity = alpha == null ? null : _Vp8AlphaDecoder(file, alpha);
        final independent = opacity == null && run.packets.length == 1;
        return (packet, selected, _) {
          final bytes = _read(packet);
          if (independent && selected) {
            // Keep the existing unscaled WebP color conversion for a keyframe.
            Vp8Picture? picture;
            return ({scaler}) {
              if (scaler == null && vp8FrameTag(bytes).key) {
                final frame = _vp8Keyframe(bytes);
                if (frame != null) return _rgb(frame);
              }
              return (picture ??= decoder.decode(bytes)).rgb(scaler: scaler);
            };
          }
          final picture = decoder.decode(bytes);
          final mask = opacity?.decode(packet);
          if (!selected) return null;
          if (mask != null &&
              (mask.width != picture.width || mask.height != picture.height)) {
            throw const FormatException(
              'VP8 color and alpha dimensions differ',
            );
          }
          return ({scaler}) =>
              picture.rgb(scaler: scaler, alpha: mask?.y.samples);
        };
      case 'ffv1':
        final stream = metadata.streams.firstWhere(
          (stream) => !stream.attached,
        );
        final entry = _isoDescriptionsByPacket[run.packets.first];
        final decoder = Ffv1Decoder(
          entry == null ? stream.width : file.unsigned(entry.data + 24, 2),
          entry == null ? stream.height : file.unsigned(entry.data + 26, 2),
          configuration.bytes,
        );
        final color = entry != null
            ? _iso!.visualColor(entry)
            : _matroska == null
            ? null
            : matroskaVideoColor(_matroska!, 'ffv1');
        return (packet, selected, _) {
          final picture = decoder.decode(_read(packet));
          if (!selected) return null;
          return ({scaler}) => picture.rgb(
            scaler: scaler,
            matrix: color?.matrix,
            fullRange: color?.fullRange,
          );
        };
      case 'msvideo1':
        final decoder = MsVideo1Decoder(
          _avi?.video1Format ?? _matroskaVideo1!.format,
        );
        return (packet, selected, palette) {
          decoder.advance(_read(packet));
          if (!selected) return null;
          final source = decoder.rgb(palette ?? _matroskaVideo1?.palette);
          return ({scaler}) => _renderRgb(source, scaler);
        };
      case 'msrle':
        final avi = _avi!;
        final decoder = MsRleDecoder(avi.rleFormat!);
        return (packet, selected, palette) {
          decoder.advance(_read(packet), raw: avi.isUncompressedRle(packet));
          if (!selected) return null;
          final source = decoder.rgb(palette!);
          return ({scaler}) => _renderRgb(source, scaler);
        };
      case 'cinepak':
        final decoder = CinepakDecoder(configuration.bytes!);
        return (packet, selected, palette) {
          decoder.advance(_read(packet));
          if (!selected) return null;
          final source = decoder.rgb(palette: palette);
          return ({scaler}) => _renderRgb(source, scaler);
        };
      case 'qtrle':
        final decoder = QuickTimeAnimationDecoder(configuration.bytes!);
        return (packet, selected, _) {
          final bytes = _read(packet);
          decoder.advance(bytes);
          if (!selected) return null;
          final source = decoder.rgb();
          return ({scaler}) => _renderRgb(source, scaler);
        };
      case 'rpza':
        final decoder = QuickTimeRpzaDecoder(configuration.bytes!);
        return (packet, selected, _) {
          final bytes = _read(packet);
          decoder.advance(bytes);
          if (!selected) return null;
          final source = decoder.rgb();
          return ({scaler}) => _renderRgb(source, scaler);
        };
      case 'smc':
        final decoder = QuickTimeSmcDecoder(configuration.bytes!);
        return (packet, selected, _) {
          final bytes = _read(packet);
          decoder.advance(bytes);
          if (!selected) return null;
          final source = decoder.rgb();
          return ({scaler}) => _renderRgb(source, scaler);
        };
      case 'av1':
        final units = Av1AccessUnits()..configure(configuration.bytes!);
        final decoder = Av1StreamDecoder();
        return (packet, selected, _) {
          final bytes = _read(packet);
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
        return (packet, selected, _) {
          final bytes = _read(packet);
          final picture = decoder.decode(bytes);
          return selected ? picture?.rgb : null;
        };
      case 'mpeg1video' || 'mpeg2video':
        final decoder = MpegStreamDecoder(configuration.bytes);
        return (packet, selected, _) {
          final bytes = _read(packet);
          if (selected) return decoder.decode(bytes).rgb;
          decoder.advance(bytes);
          return null;
        };
      default:
        final decoder = H264StreamDecoder(
          _avcDecoderConfig(configuration.nal!),
        );
        return (packet, selected, _) {
          final bytes = _read(packet);
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

  Uint8List _readPrefix(FramePacket packet, int count) =>
      _matroska?.readFramePrefix(packet, count) ??
      file.read(packet.offset, packet.size < count ? packet.size : count);

  Vp9PacketTag _vp9Tag(FramePacket packet) {
    if (_matroska?.hasEncodedFrames == true) {
      final bytes = _read(packet);
      return vp9PacketTag(
        bytes.length,
        (offset, length) =>
            Uint8List.sublistView(bytes, offset, offset + length),
      );
    }
    return vp9PacketTag(
      packet.size,
      (offset, length) => file.read(packet.offset + offset, length),
    );
  }

  Uint8List _read(FramePacket packet) {
    if (_matroska case final media?) return media.readFrame(packet);
    if (packet.size <= 0 || packet.size > 64 * 1024 * 1024) {
      throw const FormatException('Invalid video frame size');
    }
    return _systems?.read(packet) ??
        _aviNal?.read(packet) ??
        file.read(packet.offset, packet.size);
  }

  image.Image decode(FramePacket packet, {bool preview = false}) {
    if (_mixedIsoCodecs) {
      final section = _isoSectionByPacket[packet];
      if (section == null) throw const FormatException('Unknown video packet');
      if (preview && section.codec == 'vp9') {
        return Vp9Decoder.preview(_read(packet)).rgb(scaler: _previewScaler);
      }
      if (!_usesReferences(section.codec) && !_hasPresentationTransform) {
        return _decodeIndependent(packet, section.codec, preview: preview);
      }
      final frame = decodeSelected([packet]).single.frame;
      return preview && frame.hasAlpha ? _rgb(frame) : frame;
    }
    if (preview && codec == 'vp9') {
      return Vp9Decoder.preview(_read(packet)).rgb(scaler: _previewScaler);
    }
    if (_hasStatefulFrames(codec)) {
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
      final picture = H264IdrDecoder(config).decode(_read(packet));
      return picture?.rgb(scaler: _previewScaler) ??
          decodeSelected([packet]).single.frame;
    }
    if (codec == 'hevc') {
      final config = _hevcDecoderConfig(_previewNalConfigurations[packet]!);
      final picture = HevcIntraDecoder(config).decode(_read(packet));
      return picture?.rgb(scaler: _previewScaler) ??
          decodeSelected([packet]).single.frame;
    }
    if (codec == 'av1') {
      final decoder = Av1AccessUnits()
        ..configure(_previewAv1Configurations[packet]!);
      for (final frame in decoder.readSample(_read(packet))) {
        if (frame.header.type.intra && frame.shown) {
          return decodeAv1IntraImage(frame, scaler: _previewScaler);
        }
      }
      throw const FormatException('No independently decodable AV1 picture');
    }
    if (_hasPresentationTransform) {
      final frame = decodeSelected([packet]).single.frame;
      return preview && frame.hasAlpha ? _rgb(frame) : frame;
    }
    return _decodeIndependent(packet, codec, preview: preview);
  }

  image.Image _decodeIndependent(
    FramePacket packet,
    String name, {
    bool preview = false,
    List<int>? palette,
  }) {
    if (name == 'prores') {
      return _proRes(packet, preserveAlpha: !preview).rgb();
    }
    final bytes = _read(packet);
    if (isHuffYuvCodec(name)) {
      return _huffYuv.decode(bytes).rgb(includeAlpha: !preview);
    }
    if (_quickTimeFormat(packet, name) case final raw?) {
      return raw.decode(bytes, includeAlpha: !preview);
    }
    if (name == 'rawvideo' && _rawVideoFormat != null) {
      return _rawVideoFormat.decode(bytes, includeAlpha: !preview).rgb();
    }
    final frame = switch (name) {
      'mjpeg' => image.decodeJpg(bytes),
      'png' => image.decodePng(bytes),
      'rawvideo' => _avi?.decodeBitmap(
        bytes,
        palette: palette ?? _avi?.paletteFor(packet),
      ),
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
    try {
      return image.decodeWebP(riff);
    } on image.ImageException {
      // Some video keyframes use VP8 features outside the WebP subset.
      return null;
    }
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
  _Vp8AlphaRun? vp8Alpha,
  double? sampleAspect,
  Map<FramePacket, double>? sampleAspects,
  Map<int, List<int>>? aviPalettes,
});

bool _av1RandomAccess(Av1CodedFrame frame) =>
    frame.header.type == Av1FrameType.key &&
    frame.shown &&
    frame.syntax.existingSlot == null;

FramePacket _avcFieldPacket(FramePacket first, FramePacket second) {
  final earliest = first.seconds <= second.seconds ? first : second;
  var timestamp = earliest.timestamp;
  final a = first.timestamp, b = second.timestamp;
  if (a != null &&
      b != null &&
      a.numerator == b.numerator &&
      a.denominator == b.denominator) {
    final endA = a.pts + (a.duration ?? 0);
    final endB = b.pts + (b.duration ?? 0);
    final start = timestamp!;
    timestamp = frameTimestamp(
      start.pts,
      start.numerator,
      start.denominator,
      duration: (endA > endB ? endA : endB) - start.pts,
    );
  }
  return (
    offset: second.offset,
    size: second.size,
    seconds: earliest.seconds,
    timestamp: timestamp,
  );
}

bool _usesReferences(String codec) =>
    codec == 'h264' ||
    codec == 'hevc' ||
    codec == 'av1' ||
    _hasStatefulFrames(codec) ||
    isMpegVideo(codec);

bool _hasStatefulFrames(String codec) =>
    codec == 'vp8' ||
    codec == 'vp9' ||
    codec == 'ffv1' ||
    codec == 'qtrle' ||
    codec == 'rpza' ||
    codec == 'smc' ||
    codec == 'cinepak' ||
    codec == 'msrle' ||
    codec == 'msvideo1';

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
