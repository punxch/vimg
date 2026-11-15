import 'dart:typed_data';

import 'dib_palette.dart';
import 'huffyuv.dart';
import 'iso_media.dart';
import 'matroska.dart';
import 'msvideo1.dart';
import 'raw_video.dart';

RawVideoFormat? matroskaRawVideoConfiguration(Matroska media) {
  final track = _firstVideoTrack(media, 'rawvideo');
  if (track == null) return null;
  final video = media.fields(track[0xe0]!);
  final width = media.number(video[0xb0]) ?? 0;
  final height = media.number(video[0xba]) ?? 0;
  final vfw = media.text(track[0x86]) == 'V_MS/VFW/FOURCC';
  final box = video[0x2eb524];
  final config = vfw ? media.codecPrivate(track) : null;
  final Uint8List fourcc;
  if (vfw && config != null && config.length >= 20) {
    fourcc = Uint8List.sublistView(config, 16, 20);
  } else if (!vfw && box != null && box.end - box.data == 4) {
    fourcc = media.file.read(box.data, 4);
  } else {
    throw const FormatException('Missing or invalid Matroska raw video FourCC');
  }
  final color = _matroskaColor(media, video);
  return RawVideoFormat(
    String.fromCharCodes(fourcc),
    width,
    height,
    matrix: color.matrix,
    fullRange: color.fullRange,
  );
}

({int? matrix, bool? fullRange})? matroskaVideoColor(
  Matroska media,
  String codec,
) {
  final track = _firstVideoTrack(media, codec);
  return track == null
      ? null
      : _matroskaColor(media, media.fields(track[0xe0]!));
}

({int? matrix, bool? fullRange}) _matroskaColor(
  Matroska media,
  Map<int, EbmlElement> video,
) {
  final colorBox = video[0x55b0];
  final color = colorBox == null ? null : media.fields(colorBox);
  return (
    matrix: media.number(color?[0x55b1]),
    fullRange: switch (media.number(color?[0x55b9])) {
      1 => false,
      2 => true,
      _ => null,
    },
  );
}

({MsVideo1Format format, List<int>? palette}) matroskaVideo1Configuration(
  Matroska media,
) {
  final track = _firstVideoTrack(media, 'msvideo1');
  final config = track == null ? null : media.codecPrivate(track);
  if (config == null || config.length < 40) {
    throw const FormatException('Missing Microsoft Video 1 bitmap header');
  }
  final data = ByteData.sublistView(config);
  final headerSize = data.getUint32(0, Endian.little);
  if (headerSize < 40 || headerSize > config.length) {
    throw const FormatException('Invalid Microsoft Video 1 bitmap header');
  }
  final bits = data.getUint16(14, Endian.little);
  final format = MsVideo1Format(
    data.getInt32(4, Endian.little),
    data.getInt32(8, Endian.little).abs(),
    bits,
  );
  return (
    format: format,
    palette: format.indexed
        ? readDibPalette(
            config.length,
            (start, length) =>
                Uint8List.sublistView(config, start, start + length),
            bits,
          )
        : null,
  );
}

Uint8List? matroskaVideoConfiguration(Matroska media, String codec) {
  final track = _firstVideoTrack(media, codec);
  final config = track == null ? null : media.codecPrivate(track);
  if (config == null) return null;
  final start = media.text(track![0x86]) == 'V_MS/VFW/FOURCC' ? 40 : 0;
  if (config.length - start < _minimumSize(codec)) return null;
  return Uint8List.sublistView(config, start);
}

HuffYuvDecoder? matroskaHuffYuvConfiguration(Matroska media, String codec) {
  final track = _firstVideoTrack(media, codec);
  final config = track == null ? null : media.codecPrivate(track);
  return config == null ? null : readHuffYuvFormat(config);
}

Map<int, EbmlElement>? _firstVideoTrack(Matroska media, String codec) {
  final track = media.firstVideoTrack;
  return track != null && media.trackCodec(track) == codec ? track : null;
}

Uint8List? isoVideoConfiguration(
  IsoMedia media,
  String codec, {
  MediaBox? description,
}) {
  final boxType = switch (codec) {
    'hevc' => 'hvcC',
    'av1' => 'av1C',
    'ffv1' => 'glbl',
    _ => 'avcC',
  };
  final entry =
      description ??
      media.sampleDescription(
        media.sampleTable(media.child(media.firstVideoTrack(), 'mdia')),
      );
  if (entry == null) return null;
  final configuration = media
      .children(entry, skip: 78)
      .where((box) => box.type == boxType)
      .firstOrNull;
  if (configuration == null) return null;
  final size = configuration.end - configuration.data;
  if (size < _minimumSize(codec) || size > 1024 * 1024) return null;
  return media.file.read(configuration.data, size);
}

int _minimumSize(String codec) => switch (codec) {
  'hevc' => 23,
  'av1' => 4,
  'ffv1' => 6,
  _ => 7,
};
