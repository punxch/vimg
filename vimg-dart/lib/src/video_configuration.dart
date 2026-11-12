import 'dart:typed_data';

import 'iso_media.dart';
import 'matroska.dart';

Uint8List? matroskaVideoConfiguration(Matroska media, String codec) {
  final tracks = media
      .segmentElements()
      .where((box) => box.id == 0x1654ae6b)
      .firstOrNull;
  if (tracks == null) return null;
  final track = media.videoTracks(tracks).firstOrNull;
  if (track == null || media.trackCodec(track) != codec) return null;
  final config = track[0x63a2];
  if (config == null) return null;
  final start = media.text(track[0x86]) == 'V_MS/VFW/FOURCC'
      ? config.data + 40
      : config.data;
  final length = config.end - start;
  if (length < _minimumSize(codec) || length > 1024 * 1024) return null;
  return media.file.read(start, length);
}

Uint8List? isoVideoConfiguration(IsoMedia media, String codec) {
  final boxType = switch (codec) {
    'hevc' => 'hvcC',
    'av1' => 'av1C',
    _ => 'avcC',
  };
  final track = media.firstVideoTrack();
  final entry = media.sampleDescription(
    media.sampleTable(media.child(track, 'mdia')),
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
  _ => 7,
};
