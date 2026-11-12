import 'frame_packet.dart';
import 'iso_media.dart';

Iterable<FramePacket> isoCovers(IsoMedia media) sync* {
  final movie = media.movie();
  for (final box in media.children(movie)) {
    final meta = switch (box.type) {
      'meta' => box,
      'udta' => media.child(box, 'meta'),
      _ => null,
    };
    for (final data in media.coverData(meta)) {
      yield (
        seconds: 0,
        offset: data.data + 8,
        size: data.end - data.data - 8,
        timestamp: null,
      );
    }
  }
}

Iterable<FramePacket> isoFrames(
  IsoMedia media, {
  bool keyframes = false,
  FrameVisitor? onSample,
  MediaBox? selectedTrack,
}) sync* {
  final movie = media.movie();
  final track = selectedTrack ?? media.firstVideoTrack(moov: movie);
  if (track == null) return;
  final trackMedia = media.child(track, 'mdia');
  final trackTiming = media.timing(media.child(trackMedia, 'mdhd'));
  final table = media.sampleTable(trackMedia);
  if (table == null || trackTiming == null) {
    throw const FormatException('Missing video sample table or timescale');
  }
  final scale = trackTiming.scale;
  final edit = _edit(media, movie, track, scale);
  final sizes = _SampleSizes(media, table);
  final chunkMap = _Table(media, table, 'stsc', 12);
  final durations = _Table(media, table, 'stts', 8);
  final composition = _Table.optional(media, table, 'ctts', 8);
  final sync = keyframes || onSample != null
      ? _Table.optional(media, table, 'stss', 4)
      : null;
  final wideChunks = media.child(table, 'co64') != null;
  final chunks = _Table(
    media,
    table,
    wideChunks ? 'co64' : 'stco',
    wideChunks ? 8 : 4,
  );
  if (chunkMap.count == 0 || chunkMap.value(0, 0) != 1) {
    throw const FormatException('Invalid ISO media sample-to-chunk table');
  }

  var mapRow = 0;
  var durationRow = 0;
  var durationUsed = 0;
  var compositionRow = 0;
  var compositionUsed = 0;
  var syncRow = 0;
  var sample = 0;
  var timestamp = 0;
  for (var chunk = 0; chunk < chunks.count; chunk++) {
    if (mapRow + 1 < chunkMap.count &&
        chunkMap.value(mapRow + 1, 0) == chunk + 1) {
      mapRow++;
    }
    final perChunk = chunkMap.value(mapRow, 4);
    if (perChunk == 0 ||
        perChunk > sizes.count - sample ||
        chunkMap.value(mapRow, 8) != 1) {
      throw const FormatException(
        'Invalid or changing ISO media sample description',
      );
    }
    var offset = chunks.value(chunk, 0, width: wideChunks ? 8 : 4);
    for (var inChunk = 0; inChunk < perChunk; inChunk++) {
      if (durationUsed == durations.value(durationRow, 0)) {
        durationRow++;
        durationUsed = 0;
      }
      final step = durations.value(durationRow, 4);
      var pts = timestamp;
      if (composition != null) {
        if (compositionUsed == composition.value(compositionRow, 0)) {
          compositionRow++;
          compositionUsed = 0;
        }
        final delta = composition.value(compositionRow, 4);
        pts += composition.version == 1 ? _signed32(delta) : delta;
        compositionUsed++;
      }
      final size = sizes.at(sample);
      if (size <= 0 || offset < 0 || offset > media.file.length - size) {
        throw const FormatException('Invalid ISO media sample extent');
      }
      final isSync =
          sync == null ||
          (syncRow < sync.count && sync.value(syncRow, 0) == sample + 1);
      if (isSync && sync != null) syncRow++;
      final seconds = (pts - edit.start) / scale + edit.delay;
      final packet = (
        seconds: seconds,
        offset: offset,
        size: size,
        timestamp: frameTimestamp(pts, 1, scale, duration: step),
      );
      // Samples trimmed by an edit may still be needed for inter prediction.
      onSample?.call(packet, isSync);
      if ((!keyframes || isSync) &&
          pts >= edit.start &&
          (edit.end == null || seconds < edit.end!)) {
        yield packet;
      }
      timestamp += step;
      durationUsed++;
      offset += size;
      sample++;
    }
  }
  if (sample != sizes.count)
    throw const FormatException('Incomplete ISO media sample table');
}

int _signed32(int value) => value >= 0x80000000 ? value - 0x100000000 : value;

({int start, double delay, double? end}) _edit(
  IsoMedia media,
  MediaBox movie,
  MediaBox track,
  int mediaScale,
) {
  final list = _Table.optional(media, media.child(track, 'edts'), 'elst', 0);
  if (list == null || list.count == 0) return (start: 0, delay: 0, end: null);
  final movieScale =
      media.timing(media.child(movie, 'mvhd'))?.scale ?? mediaScale;
  final width = list.version == 1 ? 8 : 4;
  if (list.version > 1 || list.count > 2) {
    throw const FormatException('Unsupported ISO media edit list');
  }
  media.requireBytes(list.box, 8 + list.count * (2 * width + 4));
  var offset = list.box.data + 8;
  var delay = 0.0;
  for (var row = 0; row < list.count; row++) {
    final duration = media.file.unsigned(offset, width);
    final rawStart = media.file.unsigned(offset + width, width);
    final start = width == 4 ? _signed32(rawStart) : rawStart;
    final rate = media.file.unsigned(offset + 2 * width, 4);
    if (rate != 0x10000 || duration < 0) {
      throw const FormatException('Unsupported ISO media edit rate');
    }
    if (row == 0 && start == -1 && list.count == 2) {
      delay = duration / movieScale;
    } else if (row == list.count - 1 && start >= 0) {
      return (start: start, delay: delay, end: delay + duration / movieScale);
    } else {
      throw const FormatException('Unsupported ISO media edit list');
    }
    offset += 2 * width + 4;
  }
  throw const FormatException('Missing ISO media edit segment');
}

final class _Table {
  _Table(IsoMedia media, MediaBox? parent, String tag, int stride)
    : this._(
        media,
        media.child(parent, tag) ??
            (throw FormatException('Missing $tag sample table')),
        stride,
      );

  _Table._(this.media, this.box, this.stride) {
    media.requireBytes(box, 8);
    count = media.file.unsigned(box.data + 4, 4);
    media.requireBytes(box, 8 + stride * count);
  }

  static _Table? optional(
    IsoMedia media,
    MediaBox? parent,
    String tag,
    int stride,
  ) {
    final box = media.child(parent, tag);
    return box == null ? null : _Table._(media, box, stride);
  }

  final IsoMedia media;
  final MediaBox box;
  final int stride;
  late final int count;
  int get version => media.file.unsigned(box.data, 1);

  int value(int row, int column, {int width = 4}) {
    if (row >= count)
      throw FormatException('Incomplete ${box.type} sample table');
    return media.file.unsigned(box.data + 8 + row * stride + column, width);
  }
}

final class _SampleSizes {
  _SampleSizes(this.media, MediaBox table) {
    final full = media.child(table, 'stsz');
    final box =
        full ??
        media.child(table, 'stz2') ??
        (throw const FormatException('Missing ISO media sample sizes'));
    media.requireBytes(box, 12);
    _offset = box.data + 12;
    count = media.file.unsigned(box.data + 8, 4);
    if (full != null) {
      _constant = media.file.unsigned(box.data + 4, 4);
      _bits = 32;
    } else {
      _constant = 0;
      _bits = media.file.unsigned(box.data + 7, 1);
      if (_bits != 4 && _bits != 8 && _bits != 16) {
        throw const FormatException(
          'Unsupported ISO media compact sample sizes',
        );
      }
    }
    if (_constant == 0) media.requireBytes(box, 12 + (count * _bits + 7) ~/ 8);
  }

  final IsoMedia media;
  late final int count;
  late final int _constant;
  late final int _offset;
  late final int _bits;

  int at(int index) {
    if (_constant != 0) return _constant;
    if (_bits != 4)
      return media.file.unsigned(_offset + index * (_bits ~/ 8), _bits ~/ 8);
    final pair = media.file.unsigned(_offset + index ~/ 2, 1);
    return index.isEven ? pair >> 4 : pair & 0xf;
  }
}
