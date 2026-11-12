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

part 'transport_packets.dart';

/// MPEG-TS video samples are delimited by start codes. Index entries keep
/// their first physical byte and elementary-stream length so workers can seek
/// directly to a selected frame without buffering or indexing the whole file.
final class TransportVideo {
  TransportVideo._(this._input);

  static TransportVideo? detect(BinaryFile file) {
    final input = _TransportInput.detect(file);
    return input == null ? null : TransportVideo._(input);
  }

  final _TransportInput _input;
  late final _Program _program = _input.program();
  late final _TransportIndex _index = _scan();

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
    final data = Uint8List(frame.size);
    var written = 0;
    final pes = _PesReader((bytes, start, end, _) {
      final count = math.min(end - start, data.length - written);
      data.setRange(written, written + count, bytes, start);
      written += count;
    });
    final continuity = _Continuity();
    int? pid;
    for (final packet in _input.packets(frame.offset)) {
      pid ??= packet.pid;
      if (packet.pid != pid || !continuity.accept(packet)) continue;
      if (written == 0) {
        final start = packet.start + frame.offset - packet.position;
        if (start < packet.payload || start >= packet.end) {
          throw const FormatException('Invalid MPEG-TS access unit offset');
        }
        pes.resume(packet, start);
      } else {
        pes.add(packet);
      }
      if (written == data.length) {
        return isMpegVideo(programCodec) ? data : _lengthPrefix(data);
      }
    }
    throw const FormatException('Truncated MPEG-TS access unit');
  }

  _TransportIndex _scan() {
    final program = _program;
    final video = _AccessUnits(program.codec);
    final audio = {
      for (final entry in program.audio.entries)
        entry.key: _AudioClock(entry.value),
    };
    final videoContinuity = _Continuity();
    final pes = _PesReader(video.payload, onTime: video.timestamp);
    for (final packet in _input.packets()) {
      if (packet.pid == program.videoPid) {
        if (videoContinuity.accept(packet)) pes.add(packet);
      } else {
        audio[packet.pid]?.add(packet);
      }
    }
    pes.finish();
    video.finish();
    if (video.frames.isEmpty) {
      throw const FormatException('MPEG-TS contains no video access units');
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
    if (stamps.isEmpty) {
      throw const FormatException('Missing MPEG-TS video timestamps');
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
        : _tsFrequency / estimatedPeriod;
    final period = timing != null
        ? math.max(1, timing.$1 * _tsFrequency ~/ timing.$2)
        : estimatedPeriod;
    if (stamps.length != video.frames.length && (reordered || period == null)) {
      throw UnsupportedError(
        'MPEG-TS video has access units without a usable presentation timestamp',
      );
    }
    final pts = <int>[];
    var anchor = stamps.entries.first;
    for (var i = 0; i < video.frames.length; i++) {
      final stamp = stamps[i];
      if (stamp != null) anchor = MapEntry(i, stamp);
      final distance = i - anchor.key;
      pts.add(
        anchor.value +
            (timing == null
                ? distance * (period ?? 0)
                : (distance * timing.$1 * _tsFrequency / timing.$2).round()),
      );
    }
    var start = pts.reduce(math.min);
    // FFprobe estimates the MPEG-1 transport duration using the field rate.
    // Packet durations continue to describe complete coded frames.
    final tail = video.bitstreamCodec == 'mpeg1video'
        ? (period ?? 0) ~/ 2
        : period ?? 0;
    var end = pts.reduce(math.max) + tail;
    for (final track in audio.values) {
      final first = track.first;
      final last = track.last;
      if (first == null || last == null) continue;
      final audioStart = _unwrapTimestamp(first, start);
      start = math.min(start, audioStart);
      end = math.max(end, _unwrapTimestamp(last, end) + (track.duration ?? 0));
    }
    final (width, height) =
        video.dimensions ??
        (throw const FormatException('Missing MPEG-TS video sequence header'));
    return (
      metadata:
          VideoMetadata(end > start ? (end - start) / _tsFrequency : null, [
            VideoStream(
              codec: video.bitstreamCodec ?? program.codec,
              width: width,
              height: height,
              timeBase: '1/$_tsFrequency',
              nominalFrameRate: nominalRate,
            ),
          ]),
      packets: [
        for (final (i, frame) in video.frames.indexed)
          (
            offset: frame.offset,
            size: frame.size,
            seconds: (pts[i] - start) / _tsFrequency,
            timestamp: frameTimestamp(
              pts[i],
              1,
              _tsFrequency,
              duration: period,
            ),
          ),
      ],
      types: {for (final frame in video.frames) frame.offset: frame.type},
      mpegPictures: video.mpegPictures,
      configurations: video.configurations,
    );
  }
}

const _tsFrequency = 90000;
const _tsWrap = 1 << 33;

typedef _TransportIndex = ({
  VideoMetadata metadata,
  List<FramePacket> packets,
  Map<int, int> types,
  Map<int, MpegPictureInfo> mpegPictures,
  Map<int, Uint8List> configurations,
});

int _unwrapTimestamp(int raw, int? anchor) {
  if (anchor == null) {
    return raw >= _tsWrap - 60 * _tsFrequency ? raw - _tsWrap : raw;
  }
  final delta = (raw - anchor + (_tsWrap >> 1)) % _tsWrap - (_tsWrap >> 1);
  return anchor + delta;
}

final class _AudioClock {
  _AudioClock(this.type);

  final int type;
  int? first, last, duration;
  final _continuity = _Continuity();
  late final _PesReader _pes = _PesReader(
    _payload,
    onTime: (pts, _) {
      first ??= pts;
      last = pts;
    },
  );

  void add(_TransportPacket packet) {
    if (_continuity.accept(packet)) _pes.add(packet);
  }

  void _payload(Uint8List bytes, int start, int end, int position) {
    if (duration != null ||
        type != 0x0f ||
        end - start < 7 ||
        bytes[start] != 0xff ||
        bytes[start + 1] & 0xf6 != 0xf0) {
      return;
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
    if (index < rates.length) {
      final blocks = (bytes[start + 6] & 3) + 1;
      duration = blocks * 1024 * _tsFrequency ~/ rates[index];
    }
  }
}

typedef _AccessUnit = ({int offset, int size, int type, (int, int)? time});

final class _AccessUnits {
  _AccessUnits(String codec)
    : _hevc = codec == 'hevc',
      _mpeg = isMpegVideo(codec) ? MpegHeaders() : null;

  final bool _hevc;
  final MpegHeaders? _mpeg;
  var _gopFlags = 0;
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
    // A TS can start in the middle of a picture. Only a new picture or
    // sequence prefix can begin the first complete access unit.
    if (_frameStart < 0 && code != 0 && code != 0xb3 && code != 0xb8) return;
    _beginUnit();
    final payload = Uint8List.sublistView(bytes, 1);
    if (code == 0xb8 && payload.length >= 4) {
      _gopFlags = payload[3];
    } else if (code == 0) {
      final info = mpegPictureInfo(payload, _gopFlags);
      _gopFlags = 0;
      _beginPicture(info.type);
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
    } else if (_parameter) {
      headers.add(code, payload);
    }
  }

  void _beginUnit() {
    if (_frameStart >= 0) return;
    _frameStart = _nalStart;
    _framePosition = _nalPosition;
  }

  void _beginPicture(int type) {
    _frameType = type;
    // A PES timestamp applies to its first new access unit. A continuation
    // may start a PES without starting a picture.
    while (_timestamps.isNotEmpty && _timestamps.first.$1 <= _frameStart) {
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
      time: _frameTime,
    ));
    _frameType = null;
    _frameTime = null;
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
