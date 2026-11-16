part of 'mpeg_systems.dart';

typedef _ProgramPacket = ({int id, int start, int end});
typedef _ProgramPes = ({int data, int end, (int, int)? time});

/// ISO/IEC 11172-1 system streams and H.222.0 §2.5 program streams.
final class _ProgramInput implements _PacketSource {
  _ProgramInput(this.file);

  static _ProgramInput? detect(BinaryFile file) {
    if (file.length < 12 || file.unsigned(0, 4) != 0x000001ba) return null;
    final input = _ProgramInput(file);
    try {
      input._packEnd(0);
      return input;
    } on FormatException {
      return null;
    }
  }

  final BinaryFile file;
  _ProgramPes? _lastReadPes;

  @override
  _Program program() {
    var map = const <int, int>{};
    for (final packet in _packets()) {
      if (packet.id == 0xbc) {
        map = _streamMap(packet) ?? map;
        continue;
      }
      if (packet.id < 0xe0 || packet.id > 0xef) continue;
      final type = map[packet.id];
      // MPEG-1 and MPEG-2 video share the picture start codes. The sequence
      // extension identifies the actual generation once the index is built.
      final codec = type == null ? _unmappedVideo(packet) : _videoCodec(type);
      if (codec != null) {
        return (videoId: packet.id, codec: codec, audio: map);
      }
    }
    throw UnsupportedError('MPEG program stream has no supported video stream');
  }

  String _unmappedVideo(_ProgramPacket packet) {
    final pes = _pes(packet);
    final payload = file.read(pes.data, pes.end - pes.data);
    final first = mpegStartCodes(payload).firstOrNull;
    if (first != null &&
        _isVisualPrefix(first.code) &&
        _isMpeg4Visual(payload)) {
      return 'mpeg4';
    }
    return 'mpeg2video';
  }

  @override
  Iterable<_AudioClock> scan(_Program program, _AccessUnits video) {
    final audio = <int, _AudioClock>{};
    for (final packet in _packets()) {
      if (packet.id == program.videoId) {
        final pes = _pes(packet);
        if (pes.time case final time?) video.timestamp(time.$1, time.$2);
        final payload = file.read(pes.data, pes.end - pes.data);
        video.payload(payload, 0, payload.length, pes.data);
      } else if (packet.id == 0xbd ||
          (packet.id >= 0xc0 && packet.id <= 0xdf)) {
        final pes = _pes(packet);
        final time = pes.time;
        if (time == null || pes.data == pes.end) continue;
        final track = _audio(packet.id, program.audio[packet.id], pes);
        if (track == null) continue;
        audio
            .putIfAbsent(track.$1, _AudioClock.new)
            .timestamp(time.$1, track.$2);
      }
    }
    return audio.values;
  }

  @override
  Uint8List read(FramePacket frame, int videoId) {
    final data = Uint8List(frame.size);
    var pes = _containingPes(frame.offset, videoId);
    var start = frame.offset, written = 0;
    void append() {
      final count = math.min(pes.end - start, data.length - written);
      if (count > 0) {
        data.setRange(written, written + count, file.read(start, count));
        written += count;
      }
    }

    append();
    if (written == data.length) return data;
    for (final packet in _packets(pes.end)) {
      if (packet.id != videoId) continue;
      pes = _lastReadPes = _pes(packet);
      start = pes.data;
      append();
      if (written == data.length) return data;
    }
    throw const FormatException('Truncated MPEG program stream access unit');
  }

  _ProgramPes _containingPes(int offset, int id) {
    final cached = _lastReadPes;
    if (cached != null && offset >= cached.data && offset < cached.end) {
      return cached;
    }
    // A program stream PES has a nonzero 16-bit length. Video elementary
    // start codes cannot emulate the surrounding system-layer stream ID.
    final limit = math.max(0, offset - 65540);
    for (var end = offset + 1; end > limit;) {
      final start = math.max(limit, end - 8192);
      final bytes = file.read(start, end - start);
      for (var i = bytes.length - 4; i >= 0; i--) {
        if (bytes[i] != 0 ||
            bytes[i + 1] != 0 ||
            bytes[i + 2] != 1 ||
            bytes[i + 3] != id) {
          continue;
        }
        final packet = _extent(id, start + i);
        if (offset >= packet.end) continue;
        final pes = _pes(packet);
        if (offset >= pes.data) return _lastReadPes = pes;
      }
      if (start == limit) break;
      end = start + 3; // overlap in case the PES start code straddles the read
    }
    throw const FormatException('MPEG access unit lies outside its PES packet');
  }

  Iterable<_ProgramPacket> _packets([int from = 0]) sync* {
    var position = from;
    while (position + 4 <= file.length) {
      final prefix = file.unsigned(position, 4);
      final id = prefix & 255;
      if (prefix >> 8 != 1 || id < 0xb9) {
        throw FormatException(
          'Invalid MPEG program start code at byte $position',
        );
      }
      switch (id) {
        case 0xb9:
          position += 4;
        case 0xba:
          position = _packEnd(position);
        default:
          final packet = _extent(id, position);
          yield packet;
          position = packet.end;
      }
    }
    if (position != file.length) {
      throw const FormatException('Truncated MPEG program start code');
    }
  }

  int _packEnd(int start) {
    final marker = file.unsigned(start + 4, 1);
    if (marker & 0xc0 == 0x40) {
      final bytes = file.read(start, 14);
      final end = start + 14 + (bytes[13] & 7);
      if (bytes[4] & bytes[6] & bytes[8] & 4 != 0 &&
          bytes[9] & 1 != 0 &&
          bytes[12] & 3 == 3 &&
          end <= file.length) {
        return end;
      }
    } else if (marker & 0xf0 == 0x20) {
      final bytes = file.read(start, 12);
      if (bytes[4] & bytes[6] & bytes[8] & bytes[11] & 1 != 0 &&
          bytes[9] & 0x80 != 0) {
        return start + 12;
      }
    }
    throw const FormatException('Invalid MPEG program pack header');
  }

  _ProgramPacket _extent(int id, int start) {
    final length = file.unsigned(start + 4, 2);
    final end = start + 6 + length;
    if (end > file.length) {
      throw const FormatException('Truncated MPEG program packet');
    }
    return (id: id, start: start, end: end);
  }

  _ProgramPes _pes(_ProgramPacket packet) {
    final length = packet.end - packet.start;
    final bytes = file.read(packet.start, math.min(length, 264));
    if (bytes.length < 7)
      throw const FormatException('Empty MPEG program PES packet');
    if (bytes[6] & 0xc0 == 0x80) {
      if (bytes.length < 9 || 9 + bytes[8] > bytes.length) {
        throw const FormatException('Truncated MPEG-2 PES header');
      }
      final end = 9 + bytes[8];
      return (
        data: packet.start + end,
        end: packet.end,
        time: _mpeg2PesTime(bytes, end),
      );
    }
    var offset = 6;
    while (offset < bytes.length && bytes[offset] == 0xff) {
      offset++;
    }
    if (offset < bytes.length && bytes[offset] & 0xc0 == 0x40) {
      offset += 2; // optional P-STD buffer scale and size
    }
    if (offset >= bytes.length) {
      throw const FormatException('Truncated MPEG-1 PES header');
    }
    final prefix = bytes[offset] >> 4;
    final size = switch (prefix) {
      2 => 5,
      3 => 10,
      _ => 1,
    };
    if (size > bytes.length - offset || (size == 1 && bytes[offset] != 0x0f)) {
      throw const FormatException('Invalid MPEG-1 PES timestamp fields');
    }
    (int, int)? time;
    if (size > 1) {
      final pts = _pesTimestamp(bytes, offset, prefix);
      time = (pts, prefix == 3 ? _pesTimestamp(bytes, offset + 5, 1) : pts);
    }
    return (data: packet.start + offset + size, end: packet.end, time: time);
  }

  Map<int, int>? _streamMap(_ProgramPacket packet) {
    final length = packet.end - packet.start;
    if (length < 16 || length > 1024) {
      throw const FormatException('Invalid MPEG program stream map length');
    }
    final bytes = file.read(packet.start, length);
    if (bytes[6] & 0x80 == 0) return null;
    if (bytes[7] & 1 == 0 || _crc(bytes) != 0) {
      throw const FormatException('Invalid MPEG program stream map checksum');
    }
    var offset = 10 + _uint16(bytes, 8);
    if (offset > bytes.length - 6) {
      throw const FormatException('Truncated MPEG program descriptors');
    }
    final end = offset + 2 + _uint16(bytes, offset);
    offset += 2;
    if (end != bytes.length - 4) {
      throw const FormatException(
        'Invalid MPEG program elementary stream map length',
      );
    }
    final types = <int, int>{};
    while (offset + 4 <= end) {
      types[bytes[offset + 1]] = bytes[offset];
      offset += 4 + _uint16(bytes, offset + 2);
    }
    if (offset != end) {
      throw const FormatException(
        'Invalid MPEG program stream descriptor length',
      );
    }
    return types;
  }

  (int, int?)? _audio(int stream, int? streamType, _ProgramPes pes) {
    final length = pes.end - pes.data;
    final bytes = file.read(pes.data, math.min(4096, length));
    if (stream != 0xbd) {
      return (
        stream,
        streamType == 0x0f
            ? _adtsDuration(bytes, 0, bytes.length)
            : _mpegAudioDuration(bytes),
      );
    }
    final substream = bytes[0];
    if (length < 4) return null;
    final offset = 3 + _uint16(bytes, 2); // first access unit pointer
    final duration = switch (substream) {
      >= 0x80 && <= 0x87 => _ac3Duration(bytes, offset),
      >= 0xa0 && <= 0xaf => _dvdPcmDuration(bytes, length),
      _ => null,
    };
    // DVD subtitle and navigation streams do not supply an audio clock.
    if ((substream < 0x80 || substream > 0x8f) &&
        (substream < 0xa0 || substream > 0xaf))
      return null;
    return (0x100 + substream, duration);
  }
}

int? _mpegAudioDuration(Uint8List bytes) {
  const rates = [44100, 48000, 32000];
  for (var i = 0; i + 4 <= bytes.length; i++) {
    if (bytes[i] != 0xff || bytes[i + 1] & 0xe0 != 0xe0) continue;
    final version = (bytes[i + 1] >> 3) & 3;
    final layer = (bytes[i + 1] >> 1) & 3;
    final bitrate = bytes[i + 2] >> 4;
    final rate = (bytes[i + 2] >> 2) & 3;
    if (version == 1 ||
        layer == 0 ||
        bitrate == 15 ||
        rate == 3 ||
        (bytes[i + 3] & 3) == 2)
      continue;
    final samples = layer == 3
        ? 384
        : layer == 1 && version != 3
        ? 576
        : 1152;
    final sampleRate =
        rates[rate] >>
        (version == 3
            ? 0
            : version == 2
            ? 1
            : 2);
    return samples * _mpegClock ~/ sampleRate;
  }
  return null;
}

int? _ac3Duration(Uint8List bytes, int offset) {
  if (offset + 6 > bytes.length || _uint16(bytes, offset) != 0x0b77)
    return null;
  final rateCode = bytes[offset + 4] >> 6;
  final bsid = bytes[offset + 5] >> 3;
  if (rateCode == 3 || bsid > 10) return null;
  final rate = const [48000, 44100, 32000][rateCode] >> math.max(0, bsid - 8);
  return 1536 * _mpegClock ~/ rate;
}

int? _dvdPcmDuration(Uint8List bytes, int length) {
  if (length < 7) return null;
  final format = bytes[5];
  final rate = const [48000, 96000, 44100, 32000][(format >> 4) & 3];
  final precision = format >> 6;
  if (precision == 3) return null;
  final channels = (format & 7) + 1;
  final samples = (length - 7) * 8 ~/ ((16 + 4 * precision) * channels);
  return samples * _mpegClock ~/ rate;
}
