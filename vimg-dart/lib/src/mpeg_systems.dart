import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'binary_file.dart';
import 'frame_packet.dart';
import 'h264/parameters.dart';
import 'hevc/nal.dart';
import 'hevc/parameters.dart';
import 'metadata.dart';
import 'mpeg12/syntax.dart';
import 'rbsp.dart';

part 'program_stream.dart';
part 'transport_packets.dart';

/// MPEG systems video samples are delimited by start codes. Index entries keep
/// their first physical byte and elementary-stream length so workers can seek
/// directly to a selected frame without buffering or indexing the whole file.
final class MpegSystemsVideo {
  MpegSystemsVideo._(this._input);

  static MpegSystemsVideo? detect(BinaryFile file) {
    final _PacketSource? input =
        _ProgramInput.detect(file) ??
        _TransportInput.detect(file) ??
        _ElementaryVideo.detect(file);
    return input == null ? null : MpegSystemsVideo._(input);
  }

  final _PacketSource _input;
  late final _Program _program = _input.program();
  late final _SystemsIndex _index = _scan();

  String get programCodec => _program.codec;
  VideoMetadata metadata() => _index.metadata;

  Iterable<FramePacket> packets(bool preview, {FrameVisitor? onSample}) sync* {
    for (final packet in _index.packets) {
      final sync = _randomAccess(nalType(packet));
      onSample?.call(packet, sync);
      if (!preview || sync) yield packet;
    }
  }

  int nalType(FramePacket packet) => _index.types[packet.offset]!;
  MpegPictureInfo mpegPicture(FramePacket packet) =>
      _index.mpegPictures[packet.offset]!;
  Uint8List? configurationAt(FramePacket packet) =>
      _index.configurations[packet.offset];

  bool _randomAccess(int type) => switch (programCodec) {
    'h264' => type == 5,
    'hevc' => type >= 16 && type <= 21,
    _ => type == 1,
  };

  Uint8List read(FramePacket frame) {
    final data = _input.read(frame, _program.videoId);
    return isMpegVideo(programCodec) ? data : _lengthPrefix(data);
  }

  _SystemsIndex _scan() {
    final program = _program;
    final video = _AccessUnits(program.codec);
    final audio = _input.scan(program, video);
    video.finish();
    if (video.frames.isEmpty) {
      throw const FormatException('MPEG stream contains no video access units');
    }
    int? previous;
    var previousIndex = 0;
    final stamps = <int, int>{};
    final cadence = <int, int>{};
    var reordered = false;
    for (final (i, frame) in video.frames.indexed) {
      final raw = frame.time;
      if (raw == null) continue;
      final dts = _unwrapTimestamp(raw.$2, previous);
      final pts = _unwrapTimestamp(raw.$1, dts);
      reordered |= pts != dts;
      if (previous != null) {
        final distance = i - previousIndex;
        final delta = ((dts - previous) / distance).round();
        if (delta > 0) cadence.update(delta, (n) => n + 1, ifAbsent: () => 1);
      }
      stamps[i] = pts;
      previous = dts;
      previousIndex = i;
    }
    final elementary = _input is _ElementaryVideo;
    if (stamps.isEmpty && !elementary) {
      throw const FormatException('Missing MPEG video timestamps');
    }
    final estimatedPeriod = cadence.entries.fold<int?>(null, (mode, entry) {
      if (mode == null ||
          entry.value > cadence[mode]! ||
          (entry.value == cadence[mode] && entry.key < mode)) {
        return entry.key;
      }
      return mode;
    });
    final timing = video.timing;
    final nominalRate = timing != null
        ? timing.$2 / timing.$1
        : estimatedPeriod == null
        ? null
        : _mpegClock / estimatedPeriod;
    final period = timing != null
        ? math.max(1, timing.$1 * _mpegClock ~/ timing.$2)
        : estimatedPeriod;
    final missing = stamps.length != video.frames.length;
    final mpegTiming = missing && video.bitstreamCodec != null ? timing : null;
    if (missing && mpegTiming == null && (reordered || period == null)) {
      throw UnsupportedError(
        'MPEG video has access units without a usable presentation timestamp',
      );
    }
    final pts = mpegTiming != null
        ? _mpegPresentationTimes(video.frames, stamps, mpegTiming)
        : _presentationTimes(video.frames.length, stamps, timing, period);
    int? packetDuration(_AccessUnit frame) =>
        timing != null && frame.fields != 2
        ? math.max(1, frame.fields * timing.$1 * _mpegClock ~/ (2 * timing.$2))
        : period;
    var start = pts.reduce(math.min);
    // FFprobe estimates program-stream duration from explicit PES timestamps.
    // Inferred timestamps keep the remaining decoded pictures seekable.
    var end = start;
    for (final (i, frame) in video.frames.indexed) {
      if (_input is _ProgramInput && !stamps.containsKey(i)) continue;
      final duration = packetDuration(frame) ?? 0;
      // For MPEG-1 systems, FFprobe uses the field rate in this estimate.
      final tail = !elementary && video.bitstreamCodec == 'mpeg1video'
          ? duration ~/ 2
          : duration;
      end = math.max(end, pts[i] + tail);
    }
    for (final track in audio) {
      final first = track.first;
      final last = track.last;
      if (first == null || last == null) continue;
      final audioStart = _unwrapTimestamp(first, start);
      start = math.min(start, audioStart);
      end = math.max(end, _unwrapTimestamp(last, end) + (track.duration ?? 0));
    }
    final (width, height) =
        video.dimensions ??
        (throw const FormatException('Missing MPEG video sequence header'));
    final duration = _input is _ProgramInput
        ? (_mpegMicroseconds(end) - _mpegMicroseconds(start)) / 1000000
        : (end - start) / _mpegClock;
    return (
      metadata: VideoMetadata(duration > 0 ? duration : null, [
        VideoStream(
          codec: video.bitstreamCodec ?? program.codec,
          width: width,
          height: height,
          timeBase: '1/$_mpegClock',
          nominalFrameRate: nominalRate,
        ),
      ]),
      packets: [
        for (final (i, frame) in video.frames.indexed)
          (
            offset: frame.offset,
            size: frame.size,
            seconds: (pts[i] - start) / _mpegClock,
            timestamp: frameTimestamp(
              pts[i],
              1,
              _mpegClock,
              duration: packetDuration(frame),
            ),
          ),
      ],
      types: {for (final frame in video.frames) frame.offset: frame.type},
      mpegPictures: video.mpegPictures,
      configurations: video.configurations,
    );
  }
}

List<int> _presentationTimes(
  int count,
  Map<int, int> stamps,
  (int, int)? timing,
  int? period,
) {
  if (stamps.length == count) {
    return List.generate(count, (i) => stamps[i]!, growable: false);
  }
  var anchor = stamps.entries.first;
  return List.generate(count, (i) {
    final stamp = stamps[i];
    if (stamp != null) anchor = MapEntry(i, stamp);
    final distance = i - anchor.key;
    return anchor.value +
        (timing == null
            ? distance * (period ?? 0)
            : (distance * (timing.$1 * _mpegClock / timing.$2)).round());
  }, growable: false);
}

/// MPEG PES packets can carry several pictures with a PTS for only the first
/// picture starting in the packet. Temporal references order all pictures
/// within their GOP, including leading B-pictures after an I-picture.
List<int> _mpegPresentationTimes(
  List<_AccessUnit> frames,
  Map<int, int> stamps,
  (int, int) timing,
) {
  final order = List.generate(frames.length, (i) => i);
  order.sort((a, b) {
    final first = frames[a].mpegOrder!, second = frames[b].mpegOrder!;
    final group = first.$1.compareTo(second.$1);
    if (group != 0) return group;
    final picture = first.$2.compareTo(second.$2);
    return picture == 0 ? a.compareTo(b) : picture;
  });
  final positions = List.filled(frames.length, 0);
  var fields = 0;
  for (final index in order) {
    positions[index] = fields;
    fields += frames[index].fields;
  }
  var anchor = stamps.isEmpty
      ? order.first
      : order.firstWhere(stamps.containsKey);
  final numerator = timing.$1 * _mpegClock;
  final denominator = timing.$2 * 2;
  final result = List.filled(frames.length, 0);
  for (final index in order) {
    final stamp = stamps[index];
    if (stamp != null) anchor = index;
    final distance = positions[index] - positions[anchor];
    final ticks =
        (distance.abs() * numerator + denominator ~/ 2) ~/ denominator;
    result[index] = (stamps[anchor] ?? 0) + distance.sign * ticks;
  }
  return result;
}

const _mpegClock = 90000;
const _ptsWrap = 1 << 33;

int _mpegMicroseconds(int ticks) => ((ticks.abs() * 100 + 4) ~/ 9) * ticks.sign;

typedef _SystemsIndex = ({
  VideoMetadata metadata,
  List<FramePacket> packets,
  Map<int, int> types,
  Map<int, MpegPictureInfo> mpegPictures,
  Map<int, Uint8List> configurations,
});

int _unwrapTimestamp(int raw, int? anchor) {
  if (anchor == null) {
    return raw >= _ptsWrap - 60 * _mpegClock ? raw - _ptsWrap : raw;
  }
  final delta = (raw - anchor + (_ptsWrap >> 1)) % _ptsWrap - (_ptsWrap >> 1);
  return anchor + delta;
}

typedef _Program = ({int videoId, String codec, Map<int, int> audio});

abstract interface class _PacketSource {
  _Program program();
  Iterable<_AudioClock> scan(_Program program, _AccessUnits video);
  Uint8List read(FramePacket frame, int videoId);
}

/// A standalone H.262 or MPEG-1 elementary stream has sequence timing and
/// temporal references but carries no systems clock or PES timestamps.
final class _ElementaryVideo implements _PacketSource {
  _ElementaryVideo(this.file);

  static _ElementaryVideo? detect(BinaryFile file) {
    if (file.length < 16 || file.unsigned(0, 4) != 0x000001b3) return null;
    final bytes = file.read(0, math.min(1024, file.length));
    final units = mpegStartCodes(bytes).iterator;
    if (!units.moveNext()) return null;
    final header = units.current;
    if (!units.moveNext() ||
        !const {0, 0xb2, 0xb5, 0xb8}.contains(units.current.code)) {
      return null;
    }
    try {
      MpegSequence(Uint8List.sublistView(bytes, header.data, header.end));
      return _ElementaryVideo(file);
    } on FormatException {
      return null;
    }
  }

  final BinaryFile file;

  @override
  _Program program() => (videoId: 0, codec: 'mpeg2video', audio: const {});

  @override
  Iterable<_AudioClock> scan(_Program program, _AccessUnits video) {
    const chunkSize = 256 * 1024;
    for (var offset = 0; offset < file.length; offset += chunkSize) {
      final bytes = file.read(
        offset,
        math.min(chunkSize, file.length - offset),
      );
      video.payload(bytes, 0, bytes.length, offset);
    }
    return const [];
  }

  @override
  Uint8List read(FramePacket frame, int videoId) =>
      file.read(frame.offset, frame.size);
}

(int, int)? _mpeg2PesTime(Uint8List bytes, int size) {
  if (bytes[6] & 0x30 != 0)
    throw UnsupportedError('Scrambled MPEG PES payload');
  final flags = bytes[7] >> 6;
  if (flags == 1 || (flags == 2 && size < 14) || (flags == 3 && size < 19)) {
    throw const FormatException('Invalid MPEG PES timestamp flags');
  }
  if (flags == 0) return null;
  final pts = _pesTimestamp(bytes, 9, flags);
  return (pts, flags == 3 ? _pesTimestamp(bytes, 14, 1) : pts);
}

int _pesTimestamp(Uint8List bytes, int start, int prefix) {
  final a = bytes[start], b = bytes[start + 1], c = bytes[start + 2];
  final d = bytes[start + 3], e = bytes[start + 4];
  if (a >> 4 != prefix || a & c & e & 1 == 0) {
    throw const FormatException('Invalid MPEG PES timestamp');
  }
  return ((a & 14) << 29) | (b << 22) | ((c & 254) << 14) | (d << 7) | (e >> 1);
}

int? _adtsDuration(Uint8List bytes, int start, int end) {
  if (end - start < 7 ||
      bytes[start] != 0xff ||
      bytes[start + 1] & 0xf6 != 0xf0) {
    return null;
  }
  const rates = [
    96000,
    88200,
    64000,
    48000,
    44100,
    32000,
    24000,
    22050,
    16000,
    12000,
    11025,
    8000,
    7350,
  ];
  final index = (bytes[start + 2] >> 2) & 15;
  final blocks = (bytes[start + 6] & 3) + 1;
  return index < rates.length
      ? blocks * 1024 * _mpegClock ~/ rates[index]
      : null;
}

final class _AudioClock {
  int? first, last, duration;

  void timestamp(int pts, [int? packetDuration]) {
    first ??= pts;
    last = pts;
    if (packetDuration != null) duration = packetDuration;
  }
}

String? _videoCodec(int streamType) => switch (streamType) {
  0x01 => 'mpeg1video',
  0x02 => 'mpeg2video',
  0x1b => 'h264',
  0x24 => 'hevc',
  _ => null,
};

typedef _AccessUnit = ({
  int offset,
  int size,
  int type,
  int fields,
  (int, int)? time,
  (int, int)? mpegOrder,
});

final class _AccessUnits {
  _AccessUnits(String codec)
    : _hevc = codec == 'hevc',
      _mpeg = isMpegVideo(codec) ? MpegHeaders() : null;

  final bool _hevc;
  final MpegHeaders? _mpeg;
  var _gopFlags = 0;
  var _mpegGroup = 0, _fields = 2;
  int? _mpegReference;
  (int, int)? _mpegOrder;
  final frames = <_AccessUnit>[];
  final configurations = <int, Uint8List>{};
  final mpegPictures = <int, MpegPictureInfo>{};
  final _parameters = <(int, int), Uint8List>{};
  Uint8List? _configuration;
  String? bitstreamCodec;
  (int, int)? dimensions;
  (int, int)? timing;
  final _prefix = BytesBuilder(copy: false);
  bool _parameter = false;
  int _length = 0, _zeros = 0, _zeroPosition = 0, _lastZero = 0;
  int _nalStart = -1, _nalPosition = 0;
  int _frameStart = -1, _framePosition = 0;
  int? _frameType;
  (int, int)? _frameTime;
  final _timestamps = Queue<(int, (int, int))>();

  void timestamp(int pts, int dts) {
    _timestamps.add((_length, (pts, dts)));
  }

  void payload(Uint8List bytes, int start, int end, int position) {
    // Keep only the headers and parameter sets needed for indexing.
    var copyStart = start;
    for (var i = start; i < end; i++) {
      final byte = bytes[i];
      if (byte == 0) {
        final physical = position + i - start;
        if (_mpeg != null) {
          _zeroPosition = _lastZero;
          _lastZero = physical;
        } else if (_zeros == 0) {
          _zeroPosition = physical;
        }
        _zeros++;
      } else {
        if (byte == 1 && _zeros >= 2) {
          // MPEG video uses exactly two zero bytes. A longer zero run can
          // include meaningful trailing bytes from its previous header.
          final zeros = _mpeg == null ? _zeros : 2;
          final boundary = _length + i - start - zeros;
          _append(bytes, copyStart, math.max(copyStart, i - zeros));
          _nal();
          _nalStart = boundary;
          _nalPosition = _zeroPosition;
          copyStart = i + 1;
        }
        _zeros = 0;
      }
    }
    _append(bytes, copyStart, end);
    _length += end - start;
  }

  void _append(Uint8List bytes, int start, int end) {
    if (_nalStart < 0 || start >= end) return;
    if (_prefix.isEmpty) {
      final byte = bytes[start];
      final type = _hevc ? (byte >> 1) & 63 : byte & 31;
      _parameter = _mpeg != null
          ? byte == 0xb3 || byte == 0xb5
          : _hevc
          ? type >= 32 && type <= 34
          : type == 7 || type == 8;
    }
    final limit = _mpeg != null
        ? (_parameter ? 512 : 5)
        : (_parameter ? 65535 : 4);
    final count = math.min(end - start, limit - _prefix.length);
    if (count > 0)
      _prefix.add(Uint8List.sublistView(bytes, start, start + count));
  }

  void _nal() {
    final bytes = _prefix.takeBytes();
    if (bytes.isEmpty) return;
    final mpeg = _mpeg;
    if (mpeg != null) {
      _mpegUnit(mpeg, bytes);
      return;
    }
    final header = _hevc ? HevcNal(bytes).header : null;
    if (header != null && header.layer != 0) return;
    final type = header?.type ?? (bytes[0] & 31);
    final slice = header?.codedSlice ?? (type == 1 || type == 5);
    final startsPicture =
        slice &&
        (_hevc
            ? bytes.length >= 3 && bytes[2] & 0x80 != 0
            : bytes.length >= 2 && bytes[1] & 0x80 != 0);
    final prefix = _hevc
        ? type >= 32 && type <= 35 ||
              type == 39 ||
              type >= 41 && type <= 44 ||
              type >= 48 && type <= 55
        : type >= 6 && type <= 9 || type >= 14 && type <= 18;
    if (_frameType != null && (prefix || startsPicture)) _frame(_nalStart);
    _beginUnit();
    if (_parameter) _parameterSet(bytes);
    if (slice && _frameType == null) {
      _beginPicture(type);
      if ((_hevc && type >= 16 && type <= 21) || (!_hevc && type == 5)) {
        configurations[_framePosition] = _configuration ??= _prefixNals(
          _parameters.values,
        );
      }
    }
  }

  void _mpegUnit(MpegHeaders headers, Uint8List bytes) {
    final code = bytes[0];
    if (_frameType != null && (code == 0 || code == 0xb3 || code == 0xb8)) {
      _frame(_nalStart);
    }
    // A stream can start in the middle of a picture. Only a new picture or
    // sequence prefix can begin the first complete access unit.
    if (_frameStart < 0 && code != 0 && code != 0xb3 && code != 0xb8) return;
    _beginUnit();
    final payload = Uint8List.sublistView(bytes, 1);
    if (code == 0xb3 || code == 0xb8) {
      _mpegGroup++;
      _mpegReference = null;
    }
    if (code == 0xb8 && payload.length >= 4) {
      _gopFlags = payload[3];
    } else if (code == 0) {
      final info = mpegPictureInfo(payload, _gopFlags);
      _gopFlags = 0;
      _beginPicture(info.type, timestampPosition: _nalStart);
      _mpegOrder = (_mpegGroup, _pictureOrder(info));
      mpegPictures[_framePosition] = info;
      final sequence = headers.sequence;
      if (sequence != null) {
        // Some muxers use stream type 0x02 for both MPEG video generations.
        bitstreamCodec ??= sequence.mpeg2 ? 'mpeg2video' : 'mpeg1video';
        dimensions ??= (sequence.width, sequence.height);
        timing ??= sequence.timing;
      }
      if (info.type == 1)
        configurations[_framePosition] = headers.configuration();
    } else if (code == 0xb5 && payload.length >= 5 && payload[0] >> 4 == 8) {
      final flags = payload[3];
      if (flags & 2 != 0) {
        if (headers.sequence?.progressive == true) {
          _fields = flags & 0x80 != 0 ? 6 : 4;
        } else if (payload[4] & 0x80 != 0) {
          _fields = 3;
        }
      }
    } else if (_parameter) {
      headers.add(code, payload);
    }
  }

  int _pictureOrder(MpegPictureInfo info) {
    final temporal = info.temporalReference;
    final reference = _mpegReference;
    if (info.type == 3) {
      if (reference == null) return temporal;
      // A B-picture precedes the latest reference picture in presentation
      // order. The ten-bit counter can wrap between those two pictures.
      return reference + ((temporal - reference) & 1023) - 1024;
    }
    final next = reference == null
        ? temporal
        : reference + ((temporal - reference) & 1023);
    return _mpegReference = next;
  }

  void _beginUnit() {
    if (_frameStart >= 0) return;
    _frameStart = _nalStart;
    _framePosition = _nalPosition;
  }

  void _beginPicture(int type, {int? timestampPosition}) {
    _frameType = type;
    // A PES timestamp applies to its first new access unit. A continuation
    // may start a PES without starting a picture.
    final position = timestampPosition ?? _frameStart;
    while (_timestamps.isNotEmpty && _timestamps.first.$1 <= position) {
      _frameTime = _timestamps.removeFirst().$2;
    }
  }

  void _parameterSet(Uint8List bytes) {
    // A start-code prefix can straddle TS packets. Trim any zeros we retained
    // from the preceding payload before the terminating 0x01 was seen.
    var end = bytes.length;
    while (end > 0 && bytes[end - 1] == 0) end--;
    final nal = Uint8List.sublistView(bytes, 0, end);
    final int type, id;
    if (_hevc) {
      final unit = HevcNal(nal);
      type = unit.header.type;
      switch (type) {
        case 32:
          id = unit.rbsp().read(4);
        case 33:
          final sps = HevcSps.parse(unit);
          dimensions ??= (sps.width, sps.height);
          timing ??= sps.timing;
          id = sps.id;
        default:
          id = unit.rbsp().ue(63);
      }
    } else {
      type = nal[0] & 31;
      if (type == 7) {
        final sps = H264Sps.parse(nal);
        dimensions ??= (sps.width, sps.height);
        timing ??= sps.timing;
        id = sps.id;
      } else {
        id = Rbsp.fromNal(nal).ue(255);
      }
    }
    final previous = _parameters[(type, id)];
    if (previous != null && _sameBytes(previous, nal)) return;
    _parameters[(type, id)] = nal;
    _configuration = null;
  }

  void _frame(int end) {
    final type = _frameType;
    if (type == null) return;
    frames.add((
      offset: _framePosition,
      size: end - _frameStart,
      type: type,
      fields: _fields,
      time: _frameTime,
      mpegOrder: _mpegOrder,
    ));
    _frameType = null;
    _frameTime = null;
    _fields = 2;
    _mpegOrder = null;
    _frameStart = -1;
  }

  void finish() {
    _nal();
    _frame(_length);
  }
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Uint8List _lengthPrefix(Uint8List bytes) {
  final nals = <Uint8List>[];
  var start = -1, zeros = 0;
  for (var i = 0; i < bytes.length; i++) {
    final byte = bytes[i];
    if (byte == 0) {
      zeros++;
      continue;
    }
    if (byte == 1 && zeros >= 2) {
      if (start >= 0 && i - zeros > start) {
        nals.add(Uint8List.sublistView(bytes, start, i - zeros));
      }
      start = i + 1;
    }
    zeros = 0;
  }
  if (start >= 0 && bytes.length - zeros > start) {
    nals.add(Uint8List.sublistView(bytes, start, bytes.length - zeros));
  }
  if (nals.isEmpty) throw const FormatException('Missing MPEG-TS NAL units');
  return _prefixNals(nals);
}

Uint8List _prefixNals(Iterable<Uint8List> nals) {
  final buffer = Uint8List(nals.fold(0, (size, nal) => size + 4 + nal.length));
  final data = ByteData.sublistView(buffer);
  var offset = 0;
  for (final nal in nals) {
    data.setUint32(offset, nal.length);
    offset += 4;
    buffer.setRange(offset, offset + nal.length, nal);
    offset += nal.length;
  }
  return buffer;
}
