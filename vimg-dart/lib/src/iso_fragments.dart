part of 'iso_media.dart';

const _baseDataOffset = 0x000001;
const _sampleDescriptionIndex = 0x000002;
const _defaultSampleDuration = 0x000008;
const _defaultSampleSize = 0x000010;
const _defaultSampleFlags = 0x000020;
const _durationIsEmpty = 0x010000;
const _defaultBaseIsMoof = 0x020000;

const _runDataOffset = 0x000001;
const _firstSampleFlags = 0x000004;
const _sampleDuration = 0x000100;
const _sampleSize = 0x000200;
const _sampleFlags = 0x000400;
const _compositionOffset = 0x000800;
const _nonSync = 0x010000;
const _dependsOnOtherSamples = 0x01000000;

typedef _FragmentDefaults = ({
  int description,
  int duration,
  int size,
  int flags,
});
typedef _MovieFragments = ({
  Map<MediaBox, _FragmentTrack> tracks,
  double start,
  double? duration,
});

_MovieFragments? _readMovieFragments(IsoMedia media) {
  final movie = media.movie();
  final extendsMovie = media.child(movie, 'mvex');
  if (extendsMovie == null) return null;

  final fragments = <MediaBox>[];
  final data = <MediaBox>[];
  for (final box in media.boxes(0, media.file.length)) {
    if (box.type == 'moof') fragments.add(box);
    if (box.type == 'mdat') data.add(box);
  }
  if (fragments.isEmpty) return null;

  final defaults = <int, _FragmentDefaults>{};
  for (final box
      in media.children(extendsMovie).where((box) => box.type == 'trex')) {
    media.requireBytes(box, 24);
    _fullBoxFlags(media, box);
    final id = media.file.unsigned(box.data + 4, 4);
    if (defaults.containsKey(id)) {
      throw FormatException('Duplicate track defaults for ISO media track $id');
    }
    defaults[id] = (
      description: media.file.unsigned(box.data + 8, 4),
      duration: media.file.unsigned(box.data + 12, 4),
      size: media.file.unsigned(box.data + 16, 4),
      flags: media.file.unsigned(box.data + 20, 4),
    );
  }

  final tracks = <MediaBox, _FragmentTrack>{};
  final tracksById = <int, _FragmentTrack>{};
  for (final box in media.children(movie).where((box) => box.type == 'trak')) {
    final id = _trackId(media, box);
    if (tracksById.containsKey(id)) {
      throw FormatException('Duplicate ISO media track ID $id');
    }
    final trackMedia = media.child(box, 'mdia');
    final scale = media.timing(media.child(trackMedia, 'mdhd'))?.scale;
    if (scale == null) throw FormatException('Missing timescale for track $id');
    final track = _FragmentTrack(
      scale,
      _edit(media, movie, box, scale, fragmented: true),
    );
    tracks[box] = tracksById[id] = track;
    final table = media.sampleTable(trackMedia);
    if (table != null) {
      for (final sample in _tableSamples(media, table, needSync: false)) {
        track.observe(sample);
      }
    }
  }

  for (final fragment in fragments) {
    var implicitBase = fragment.start;
    for (final box
        in media.children(fragment).where((box) => box.type == 'traf')) {
      final tfhd =
          media.child(box, 'tfhd') ??
          (throw const FormatException('Missing track fragment header'));
      media.requireBytes(tfhd, 8);
      final id = media.file.unsigned(tfhd.data + 4, 4);
      final track = tracksById[id];
      final inherited = defaults[id];
      if (track == null || inherited == null) {
        throw FormatException('Missing initialization for fragment track $id');
      }
      final header = _fragmentHeader(
        media,
        tfhd,
        inherited,
        fragment.start,
        implicitBase,
      );
      final tfdt = media.child(box, 'tfdt');
      var dts = tfdt == null ? track.decodeEnd : _versionedTime(media, tfdt);
      var offset = header.base;
      for (final trun
          in media.children(box).where((box) => box.type == 'trun')) {
        final run = _FragmentRun.read(
          media,
          trun,
          header.defaults,
          header.base,
          offset,
          dts,
        );
        offset = run.offset;
        if (run.count == 0) continue;
        if (header.empty) {
          throw const FormatException('Empty track fragment contains samples');
        }
        if (run.dts < track.decodeEnd) {
          throw const FormatException(
            'Overlapping or out-of-order ISO media fragments',
          );
        }
        final limit = _mediaDataEnd(data, offset);
        for (final sample in run.samples(media)) {
          if (sample.size <= 0 || sample.offset > limit - sample.size) {
            throw const FormatException(
              'Invalid ISO media fragment sample extent',
            );
          }
          track.observe(sample);
          offset = sample.offset + sample.size;
        }
        track.runs.add(run);
        dts = track.decodeEnd;
        implicitBase = offset;
      }
    }
  }

  final timed = tracks.values.where((track) => track.firstPresentation != null);
  var start = 0.0, end = 0.0;
  if (timed.isNotEmpty) {
    start = timed.map((track) => track.firstPresentation!).reduce(math.min);
    if (tracks.values.any((track) => track.edit.delay > 0))
      start = math.min(0, start);
    end = timed.map((track) => track.presentationEnd).reduce(math.max);
  }

  final timing = media.timing(media.child(movie, 'mvhd'));
  var duration = end - start;
  if (timing != null) {
    final declared = timing.duration ?? 0;
    final mehd = media.child(extendsMovie, 'mehd');
    final total = mehd == null
        ? declared
        : math.max(declared, _versionedTime(media, mehd));
    duration = math.max(duration, total / timing.scale);
  }
  return (
    tracks: tracks,
    start: start,
    duration: duration > 0 ? duration : null,
  );
}

final class _FragmentTrack {
  _FragmentTrack(this.scale, this.edit);

  final int scale;
  final _TrackEdit edit;
  final runs = <_FragmentRun>[];
  int? _firstDecode;
  int _compositionShift = 0;
  int decodeEnd = 0;
  double? _firstPresentation;

  // Align the playback clock with FFmpeg's handling of negative composition
  // offsets. An explicit edit already maps media time to the movie timeline.
  double get playbackShift =>
      edit.start == null ? _compositionShift / scale : 0;

  double? get firstPresentation =>
      _firstPresentation == null ? null : _firstPresentation! + playbackShift;

  double get presentationEnd =>
      edit.end ?? firstPresentation! + (decodeEnd - _firstDecode!) / scale;

  void observe(_IsoSample sample) {
    _firstDecode ??= sample.dts;
    decodeEnd = _addTime(sample.dts, sample.duration);
    _compositionShift = math.max(_compositionShift, sample.dts - sample.pts);
    final seconds = (sample.pts - (edit.start ?? 0)) / scale + edit.delay;
    if (_inEdit(edit, sample.pts, seconds, fragmented: true)) {
      _firstPresentation = math.min(_firstPresentation ?? seconds, seconds);
    }
  }

  Iterable<_IsoSample> samples(IsoMedia media) =>
      runs.expand((run) => run.samples(media));
}

int _trackId(IsoMedia media, MediaBox track) {
  final box =
      media.child(track, 'tkhd') ??
      (throw const FormatException('Missing ISO media track header'));
  final offset = _boxVersion(media, box, maximum: 1) == 1 ? 20 : 12;
  media.requireBytes(box, offset + 4);
  final id = media.file.unsigned(box.data + offset, 4);
  if (id == 0) throw const FormatException('Invalid ISO media track ID');
  return id;
}

int _boxVersion(IsoMedia media, MediaBox box, {required int maximum}) {
  media.requireBytes(box, 4);
  final version = media.file.unsigned(box.data, 1);
  if (version > maximum) {
    throw FormatException('Unsupported ${box.type} version $version');
  }
  return version;
}

int _fullBoxFlags(IsoMedia media, MediaBox box, {int maximumVersion = 0}) {
  _boxVersion(media, box, maximum: maximumVersion);
  return media.file.unsigned(box.data + 1, 3);
}

int _versionedTime(IsoMedia media, MediaBox box) {
  final width = _boxVersion(media, box, maximum: 1) == 1 ? 8 : 4;
  media.requireBytes(box, 4 + width);
  final value = media.file.unsigned(box.data + 4, width);
  if (value < 0) throw FormatException('Invalid ${box.type} timestamp');
  return value;
}

({int base, _FragmentDefaults defaults, bool empty}) _fragmentHeader(
  IsoMedia media,
  MediaBox box,
  _FragmentDefaults inherited,
  int moof,
  int implicitBase,
) {
  final flags = _fullBoxFlags(media, box);
  var offset = box.data + 8;
  int? option(int flag, [int width = 4]) {
    if ((flags & flag) == 0) return null;
    media.requireBytes(box, offset - box.data + width);
    final value = media.file.unsigned(offset, width);
    offset += width;
    return value;
  }

  final base =
      option(_baseDataOffset, 8) ??
      ((flags & _defaultBaseIsMoof) != 0 ? moof : implicitBase);
  if (base < 0 || base > media.file.length) {
    throw const FormatException('Invalid ISO media fragment data offset');
  }
  return (
    base: base,
    defaults: (
      description: option(_sampleDescriptionIndex) ?? inherited.description,
      duration: option(_defaultSampleDuration) ?? inherited.duration,
      size: option(_defaultSampleSize) ?? inherited.size,
      flags: option(_defaultSampleFlags) ?? inherited.flags,
    ),
    empty: (flags & _durationIsEmpty) != 0,
  );
}

/// Index only runs. Their sample fields are read from the container on demand.
final class _FragmentRun {
  _FragmentRun.read(
    IsoMedia media,
    MediaBox box,
    this.defaults,
    int base,
    int previousEnd,
    this.dts,
  ) {
    media.requireBytes(box, 8);
    flags = _fullBoxFlags(media, box, maximumVersion: 1);
    signedComposition = media.file.unsigned(box.data, 1) == 1;
    count = media.file.unsigned(box.data + 4, 4);
    var row = box.data + 8;
    if ((flags & _runDataOffset) != 0) {
      media.requireBytes(box, 12);
      offset = base + _signed32(media.file.unsigned(row, 4));
      row += 4;
    } else {
      offset = previousEnd;
    }
    var initialFlags = defaults.flags;
    if ((flags & _firstSampleFlags) != 0) {
      if ((flags & _sampleFlags) != 0) {
        throw const FormatException(
          'Conflicting ISO media fragment sample flags',
        );
      }
      media.requireBytes(box, row - box.data + 4);
      initialFlags = media.file.unsigned(row, 4);
      row += 4;
    }
    final stride =
        [
          _sampleDuration,
          _sampleSize,
          _sampleFlags,
          _compositionOffset,
        ].where((flag) => (flags & flag) != 0).length *
        4;
    media.requireBytes(box, row - box.data + count * stride);
    entries = row;
    firstFlags = initialFlags;
  }

  final _FragmentDefaults defaults;
  final int dts;
  late final int flags, count, offset, entries, firstFlags;
  late final bool signedComposition;

  Iterable<_IsoSample> samples(IsoMedia media) sync* {
    var entry = entries, position = offset, decode = dts;
    final hasDuration = (flags & _sampleDuration) != 0;
    final hasSize = (flags & _sampleSize) != 0;
    final hasFlags = (flags & _sampleFlags) != 0;
    final hasComposition = (flags & _compositionOffset) != 0;
    int field() {
      final value = media.file.unsigned(entry, 4);
      entry += 4;
      return value;
    }

    for (var i = 0; i < count; i++) {
      final duration = hasDuration ? field() : defaults.duration;
      final size = hasSize ? field() : defaults.size;
      final sampleFlags = hasFlags
          ? field()
          : (i == 0 ? firstFlags : defaults.flags);
      final composition = hasComposition ? field() : 0;
      final delta = signedComposition ? _signed32(composition) : composition;
      yield (
        dts: decode,
        pts: _addTime(decode, delta),
        offset: position,
        size: size,
        duration: duration,
        description: defaults.description,
        sync: (sampleFlags & (_nonSync | _dependsOnOtherSamples)) == 0,
      );
      decode = _addTime(decode, duration);
      position += size;
    }
  }
}

int _addTime(int time, int delta) {
  final result = time + delta;
  if (delta > 0 && result < time) {
    throw const FormatException('ISO media timestamp overflow');
  }
  return result;
}

int _mediaDataEnd(List<MediaBox> boxes, int offset) {
  var low = 0, high = boxes.length;
  while (low < high) {
    final mid = (low + high) >> 1;
    if (boxes[mid].data <= offset) {
      low = mid + 1;
    } else {
      high = mid;
    }
  }
  if (low == 0 || offset >= boxes[low - 1].end) {
    throw const FormatException('ISO media fragment starts outside media data');
  }
  return boxes[low - 1].end;
}
