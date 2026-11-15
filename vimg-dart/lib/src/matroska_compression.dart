part of 'matroska.dart';

const _maxFramePayload = 64 * 1024 * 1024;

typedef _ContentCompression = ({
  int order,
  int scope,
  int algorithm,
  Uint8List settings,
});

List<_ContentCompression> _readContentEncodings(
  Matroska media,
  EbmlElement parent,
) {
  final result = <_ContentCompression>[];
  final orders = <int>{};
  for (final item in media.elements(parent.data, parent.end)) {
    if (item.id != 0x6240) continue;
    final fields = media.fields(item);
    final order = media.number(fields[0x5031]) ?? 0;
    final scope = media.number(fields[0x5032]) ?? 1;
    final type = media.number(fields[0x5033]) ?? 0;
    if (order < 0 || !orders.add(order) || scope < 1) {
      throw const FormatException(
        'Invalid Matroska content encoding order or scope',
      );
    }
    if (scope & ~3 != 0) {
      throw UnsupportedError('Matroska content encoding scope $scope');
    }
    if (type != 0 || fields.containsKey(0x5035)) {
      throw UnsupportedError('Encrypted Matroska content');
    }
    final compression = fields[0x5034];
    if (compression == null) {
      throw const FormatException(
        'Missing Matroska content compression settings',
      );
    }
    final details = media.fields(compression);
    final algorithm = media.number(details[0x4254]) ?? 0;
    if (algorithm < 0 || algorithm > 3) {
      throw UnsupportedError('Matroska compression algorithm $algorithm');
    }
    final settings = details[0x4255];
    final length = settings == null ? 0 : settings.end - settings.data;
    if (length > _maxFramePayload) {
      throw const FormatException('Oversized Matroska compression settings');
    }
    result.add((
      order: order,
      scope: scope,
      algorithm: algorithm,
      settings: settings == null
          ? Uint8List(0)
          : media.file.read(settings.data, length),
    ));
  }
  result.sort((a, b) => b.order.compareTo(a.order));
  return result;
}

Uint8List _restoreContent(
  Uint8List bytes,
  Iterable<_ContentCompression> entries,
  int limit,
) {
  var decoded = bytes;
  for (final entry in entries) {
    decoded = switch (entry.algorithm) {
      0 => _inflateZlib(decoded, limit),
      1 => _inflateBzip2(decoded, limit),
      2 => _inflateLzo(decoded, limit),
      3 => _prepend(entry.settings, decoded, limit),
      _ => throw StateError('Unrecognized Matroska compression'),
    };
  }
  return decoded;
}

Uint8List _prepend(Uint8List prefix, Uint8List bytes, int limit) {
  if (bytes.length > limit - prefix.length) {
    throw const FormatException('Decoded Matroska content exceeds size limit');
  }
  if (prefix.isEmpty) return bytes;
  return Uint8List(prefix.length + bytes.length)
    ..setRange(0, prefix.length, prefix)
    ..setRange(prefix.length, prefix.length + bytes.length, bytes);
}

Uint8List _inflateZlib(Uint8List bytes, int limit) {
  if (bytes.length < 6 ||
      bytes[0] & 15 != 8 ||
      bytes[0] >> 4 > 7 ||
      ((bytes[0] << 8) | bytes[1]) % 31 != 0) {
    throw const FormatException('Invalid Matroska zlib header');
  }
  if (bytes[1] & 32 != 0) {
    throw UnsupportedError('Matroska zlib preset dictionary');
  }
  final compressed = InputMemoryStream(
    Uint8List.sublistView(bytes, 2, bytes.length - 4),
  );
  final output = _LimitedInflateOutput(limit);
  try {
    final decoder = Inflate.stream(
      compressed,
      output: output,
      throwOnError: true,
    );
    if (!decoder.isFinished || !compressed.isEOS) {
      throw const FormatException('Invalid Matroska deflate payload');
    }
  } on ArchiveException catch (error) {
    throw FormatException('Invalid compressed Matroska block: $error');
  }
  final result = output.getBytes();
  if (getAdler32(result) !=
      ByteData.sublistView(bytes).getUint32(bytes.length - 4)) {
    throw const FormatException('Invalid Matroska zlib checksum');
  }
  return result;
}

Uint8List _inflateBzip2(Uint8List bytes, int limit) {
  final output = OutputMemoryStream();
  try {
    if (!BZip2Decoder().decodeStream(
      InputMemoryStream(bytes),
      output,
      verify: true,
      maxOutputSize: limit,
    )) {
      throw const FormatException('Invalid Matroska bzip2 payload');
    }
  } on ArchiveException catch (error) {
    throw FormatException('Invalid compressed Matroska block: $error');
  }
  return output.getBytes();
}

final class _LimitedInflateOutput extends OutputMemoryStream {
  _LimitedInflateOutput(this.limit);

  final int limit;

  void _reserve(int bytes) {
    if (bytes > limit - length) {
      throw const FormatException(
        'Decoded Matroska content exceeds size limit',
      );
    }
  }

  @override
  void writeByte(int value) {
    _reserve(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _reserve(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    _reserve(stream.length);
    super.writeStream(stream);
  }

  @override
  void writeBackReference(int distance, int count) {
    _reserve(count);
    super.writeBackReference(distance, count);
  }
}

// LZO1X instructions combine an optional history match with a literal run.
Uint8List _inflateLzo(Uint8List bytes, int limit) {
  final output = _LimitedInflateOutput(limit);
  var input = 0;
  int next() {
    if (input >= bytes.length) {
      throw const FormatException('Truncated Matroska LZO payload');
    }
    return bytes[input++];
  }

  int matches(int length, int maximum) {
    if (length != 0) return length;
    var total = maximum;
    var extra = next();
    while (extra == 0) {
      total += 255;
      if (total > limit) {
        throw const FormatException('Oversized Matroska LZO run');
      }
      extra = next();
    }
    return total + extra;
  }

  void literals(int count) {
    if (count > bytes.length - input) {
      throw const FormatException('Truncated Matroska LZO literals');
    }
    output.writeBytes(Uint8List.sublistView(bytes, input, input + count));
    input += count;
  }

  var state = 0;
  if (bytes.isNotEmpty && bytes.first > 17) {
    final count = next() - 17;
    literals(count);
    state = math.min(4, count);
  }
  while (true) {
    final opcode = next();
    final int count, distance, tail;
    if (opcode < 16) {
      if (state == 0) {
        literals(3 + matches(opcode, 15));
        state = 4;
        continue;
      }
      count = state == 4 ? 3 : 2;
      distance = (state == 4 ? 2049 : 1) + (opcode >> 2) + (next() << 2);
      tail = opcode & 3;
    } else if (opcode < 64) {
      final longDistance = opcode < 32;
      final mask = longDistance ? 7 : 31;
      count = 2 + matches(opcode & mask, mask);
      final offset = next() | (next() << 8);
      final back = (offset >> 2) + (longDistance ? (opcode & 8) << 11 : 0);
      if (longDistance && back == 0) {
        if (count != 3 || input != bytes.length) {
          throw const FormatException('Invalid Matroska LZO end marker');
        }
        return output.getBytes();
      }
      distance = back + (longDistance ? 16384 : 1);
      tail = offset & 3;
    } else {
      count = 1 + (opcode >> 5);
      distance = 1 + ((opcode >> 2) & 7) + (next() << 3);
      tail = opcode & 3;
    }
    if (distance > output.length) {
      throw const FormatException('Invalid Matroska LZO match distance');
    }
    output.writeBackReference(distance, count);
    literals(tail);
    state = tail;
  }
}
