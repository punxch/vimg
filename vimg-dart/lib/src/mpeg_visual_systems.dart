part of 'mpeg_systems.dart';

typedef Mpeg4SystemPicture = ({
  Mpeg4PictureType type,
  bool coded,
  int ticks,
  int resolution,
  int? fixedIncrement,
  Mpeg4Clock clock,
  Uint8List? configuration,
});

bool _isVisualPrefix(int code) =>
    code <= 0x2f ||
    code == 0xb0 ||
    code == 0xb2 ||
    code == 0xb3 ||
    code == 0xb5;

bool _isMpeg4Visual(Uint8List bytes) {
  final headers = Mpeg4Headers();
  try {
    for (final unit in mpegStartCodes(bytes)) {
      if (unit.code == 0xb6 && headers.volume == null) return false;
      final header = headers.readUnit(
        unit.code,
        Uint8List.sublistView(bytes, unit.data, unit.end),
        timingOnly: true,
      );
      if (header != null) return true;
    }
  } on FormatException {
    return false;
  } on UnsupportedError {
    return false;
  }
  return false;
}

extension _VisualAccessUnits on _AccessUnits {
  void _visualUnit(Mpeg4Headers headers, Uint8List bytes) {
    final code = bytes.first;
    final vop = code == 0xb6;
    if (_frameType != null && (vop || _isVisualPrefix(code))) _frame(_nalStart);
    if (vop && headers.volume == null) {
      // A transport recording can start before the first complete VOL.
      _clearPicture();
      return;
    }
    if (!vop && !_isVisualPrefix(code)) return;
    _beginUnit();
    final clock = headers.clock;
    final header = headers.readUnit(
      code,
      Uint8List.sublistView(bytes, 1),
      timingOnly: true,
    );
    if (header == null) return;
    _beginPicture(
      header.coded ? header.type.index + 1 : 0,
      timestampPosition: _nalStart,
    );
    final volume = header.volume;
    dimensions ??= (volume.width, volume.height);
    visualPictures[_framePosition] = (
      type: header.type,
      coded: header.coded,
      ticks: header.pts,
      resolution: volume.resolution,
      fixedIncrement: volume.fixedIncrement,
      clock: clock,
      configuration: header.coded && header.type == Mpeg4PictureType.intra
          ? headers.configuration
          : null,
    );
  }
}

_SystemsIndex _scanVisual(
  _AccessUnits video,
  Iterable<_AudioClock> audio,
  Map<int, int> stamped, {
  required bool elementary,
  required bool programStream,
}) {
  final clock = elementary ? 1200000 : _mpegClock;
  final frames = video.frames;
  final pictures = [
    for (final frame in frames) video.visualPictures[frame.offset]!,
  ];
  int rescale(int ticks, int resolution) =>
      (ticks.abs() * clock + resolution ~/ 2) ~/ resolution * ticks.sign;
  final streamPts = [for (final p in pictures) rescale(p.ticks, p.resolution)];
  final order = [for (var i = 0; i < frames.length; i++) i];
  order.sort((a, b) => _compareVisualTimes(streamPts, a, b));

  // PES timestamps identify the first VOP starting in the PES payload.
  // Offset the intervening VOPs by their elementary presentation times.
  var anchor = order.firstWhere(stamped.containsKey, orElse: () => order.first);
  final pts = List<int>.filled(frames.length, 0);
  for (final index in order) {
    final stamp = stamped[index];
    if (stamp != null) anchor = index;
    final current = pictures[index], from = pictures[anchor];
    final delta = current.resolution == from.resolution
        ? rescale(current.ticks - from.ticks, current.resolution)
        : streamPts[index] - streamPts[anchor];
    pts[index] = (stamped[anchor] ?? streamPts[anchor]) + delta;
  }

  var references = 0;
  final hidden = <int>{};
  for (final (i, picture) in pictures.indexed) {
    if (picture.type == Mpeg4PictureType.bidirectional) {
      if (references < 2) hidden.add(i);
    } else if (picture.coded &&
        (picture.type == Mpeg4PictureType.intra || references > 0)) {
      references = math.min(2, references + 1);
    } else if (references == 0) {
      hidden.add(i);
    }
  }
  final displayed = [
    for (final i in order)
      if (!hidden.contains(i)) i,
  ]..sort((a, b) => _compareVisualTimes(pts, a, b));
  if (displayed.isEmpty) {
    throw const FormatException(
      'MPEG-4 stream contains no random-access picture',
    );
  }

  final last = displayed.last;
  final tail = pictures[last];
  final durations = <int, int>{}, cadence = <int, int>{};
  final bitstreamCadence = <int, int>{};
  var uniformResolution = true;
  for (var i = 1; i < displayed.length; i++) {
    final before = displayed[i - 1];
    final after = displayed[i];
    final delta = pts[after] - pts[before];
    if (delta > 0) {
      durations[before] = delta;
      cadence.update(delta, (count) => count + 1, ifAbsent: () => 1);
    }
    if (pictures[before].resolution != tail.resolution)
      uniformResolution = false;
    final ticks = pictures[after].ticks - pictures[before].ticks;
    if (ticks > 0)
      bitstreamCadence.update(ticks, (count) => count + 1, ifAbsent: () => 1);
  }
  final fixed = tail.fixedIncrement;
  final nativePeriod = fixed != null && fixed > 0
      ? fixed
      : uniformResolution
      ? _mode(bitstreamCadence)
      : null;
  final bitstreamPeriod = nativePeriod == null
      ? null
      : math.max(1, rescale(nativePeriod, tail.resolution));
  final period = _mode(cadence) ?? bitstreamPeriod ?? clock ~/ 25;
  final usesBitstreamPeriod =
      bitstreamPeriod != null && (period - bitstreamPeriod).abs() <= 1;
  if (usesBitstreamPeriod) {
    durations[last] = math.max(
      1,
      rescale(tail.ticks + nativePeriod!, tail.resolution) - streamPts[last],
    );
  }
  // Program stream probes estimate the extent from explicit PES timestamps.
  final lastTimed = programStream && stamped.isNotEmpty
      ? displayed.reversed.firstWhere(stamped.containsKey, orElse: () => last)
      : last;
  var start = pts[displayed.first];
  var end = pts[lastTimed] + (durations[lastTimed] ?? period);
  for (final track in audio) {
    if (track.first case final first?)
      start = math.min(start, _unwrapTimestamp(first, start));
    if (track.last case final last?) {
      end = math.max(end, _unwrapTimestamp(last, end) + (track.duration ?? 0));
    }
  }
  final (width, height) = video.dimensions!;
  final nominalRate = cadence.keys.every((delta) => (delta - period).abs() <= 1)
      ? (usesBitstreamPeriod ? tail.resolution / nativePeriod! : clock / period)
      : null;
  final duration = programStream
      ? (_mpegMicroseconds(end) - _mpegMicroseconds(start)) / 1000000
      : (end - start) / clock;
  return (
    metadata: VideoMetadata(duration, [
      VideoStream(
        codec: 'mpeg4',
        width: width,
        height: height,
        timeBase: '1/$clock',
        nominalFrameRate: nominalRate,
      ),
    ]),
    packets: [
      for (final (i, frame) in frames.indexed)
        (
          offset: frame.offset,
          size: frame.size,
          seconds: (pts[i] - start) / clock,
          timestamp: frameTimestamp(
            elementary ? pts[i] - start : pts[i],
            1,
            clock,
            duration: durations[i] ?? period,
          ),
          subframe: null,
        ),
    ],
    types: {for (final frame in frames) frame.offset: frame.type},
    mpegPictures: const {},
    configurations: const {},
    visualPictures: video.visualPictures,
    hidden: {for (final i in hidden) frames[i].offset},
  );
}

int _compareVisualTimes(List<int> pts, int a, int b) {
  final time = pts[a].compareTo(pts[b]);
  return time == 0 ? a.compareTo(b) : time;
}
