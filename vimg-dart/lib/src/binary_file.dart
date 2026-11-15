import 'dart:io';
import 'dart:typed_data';

/// Positional reads with a small cache for container headers.
final class BinaryFile {
  BinaryFile(this._file) : length = _file.lengthSync();

  final RandomAccessFile _file;
  final int length;
  var _start = 0;
  var _buffer = Uint8List(0);

  Uint8List read(int offset, int count) {
    if (offset < 0 || count < 0 || offset > length - count) {
      throw const FormatException('Truncated container');
    }
    if (count > 8192) {
      _file.setPositionSync(offset);
      return _readExactly(count);
    }
    if (offset < _start || offset + count > _start + _buffer.length) {
      _start = offset;
      _file.setPositionSync(offset);
      final available = length - offset;
      _buffer = _readExactly(available < 8192 ? available : 8192);
    }
    return Uint8List.sublistView(
      _buffer,
      offset - _start,
      offset - _start + count,
    );
  }

  Uint8List _readExactly(int count) {
    final bytes = _file.readSync(count);
    if (bytes.length != count) {
      throw const FormatException('Truncated container');
    }
    return bytes;
  }

  int unsigned(int offset, int count) {
    if (count < 1 || count > 8) {
      throw const FormatException('Invalid integer width');
    }
    return readBigEndian(read(offset, count));
  }
}

int readBigEndian(Uint8List bytes) {
  var value = 0;
  for (final byte in bytes) {
    value = (value << 8) | byte;
  }
  return value;
}
