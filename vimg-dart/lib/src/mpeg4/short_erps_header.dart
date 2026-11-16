import '../rbsp.dart';

typedef H263ErpsBufferSize = ({
  int width,
  int height,
  int capacity,
  bool reset,
});

({int columns, int rows}) h263ErpsGrid(
  H263ErpsBufferSize size,
  (int, int) dimensions,
) {
  final (width, height) = dimensions;
  return (
    columns: (width + 16 * size.width - 1) ~/ (16 * size.width),
    rows: (height + 16 * size.height - 1) ~/ (16 * size.height),
  );
}

typedef H263ErpsIndex = ({bool longTerm, int index});

enum H263ErpsOperation {
  removeShort,
  removeLong,
  removeShortRegions,
  removeLongRegions,
  assignLong,
  limitLong,
  resize,
}

typedef H263ErpsCommand = ({
  H263ErpsOperation operation,
  int argument,
  int? destination,
  H263ErpsBufferSize? size,
  String? removal,
});

final class H263Erps {
  H263Erps._({
    required this.number,
    required this.multiple,
    required this.twoBackward,
    required this.sliding,
    required this.remapping,
    required this.commands,
    required this.bufferSize,
    required (int, int) dimensions,
  }) : _dimensions = dimensions;

  final int number;
  final bool multiple, twoBackward, sliding;
  final List<H263ErpsIndex> remapping;
  final List<H263ErpsCommand> commands;
  final H263ErpsBufferSize? bufferSize;
  final (int, int) _dimensions;

  H263ErpsBufferSize? get size => commands.isEmpty ? null : commands.first.size;

  static H263Erps read(
    Rbsp bits,
    int number, {
    required bool intra,
    required bool bidirectional,
    required (int, int) dimensions,
    required H263ErpsBufferSize? previousSize,
  }) {
    final multiple = !intra && bits.flag();
    final remapping = <H263ErpsIndex>[];
    if (!intra) {
      var prediction = number;
      while (true) {
        // Table U.2: 1 = negative, 010 = positive, 011 = long, 001 = end.
        final code = bits.flag() ? 4 : bits.read(2);
        if (code == 1) break;
        if (code == 0) {
          throw const FormatException('Invalid H.263+ ERPS remapping');
        }
        final value = h263ErpsVlc(bits);
        if (code == 3) {
          remapping.add((longTerm: true, index: value));
        } else {
          if (value >= 1023) {
            throw const FormatException('Invalid H.263+ ERPS remapping');
          }
          prediction =
              (prediction + (code == 2 ? value + 1 : -value - 1)) % 1024;
          remapping.add((longTerm: false, index: prediction));
        }
      }
      if (!multiple && remapping.length > (bidirectional ? 2 : 1)) {
        throw const FormatException('Too many H.263+ ERPS remappings');
      }
    }
    final twoBackward = bidirectional && multiple && bits.flag();
    final sliding = !bidirectional && bits.flag();
    final commands = !bidirectional && !sliding
        ? _readCommands(bits, number, dimensions, previousSize)
        : const <H263ErpsCommand>[];
    return H263Erps._(
      number: number,
      multiple: multiple,
      twoBackward: twoBackward,
      sliding: sliding,
      remapping: remapping,
      commands: commands,
      bufferSize:
          (commands.isEmpty ? null : commands.first.size) ?? previousSize,
      dimensions: dimensions,
    );
  }

  H263Erps readGroup(
    Rbsp bits, {
    required bool intra,
    required bool bidirectional,
  }) {
    final groupNumber = bits.flag() ? bits.read(10) : number;
    if (groupNumber != number) {
      throw const FormatException('H.263+ ERPS group picture number differs');
    }
    if (bits.flag()) return this;
    final group = read(
      bits,
      groupNumber,
      intra: intra,
      bidirectional: bidirectional,
      dimensions: _dimensions,
      previousSize: bufferSize,
    );
    if (group.sliding != sliding ||
        group.commands.any((command) => !commands.contains(command))) {
      throw const FormatException('Invalid H.263+ ERPS group buffer commands');
    }
    return group;
  }
}

List<H263ErpsCommand> _readCommands(
  Rbsp bits,
  int number,
  (int, int) dimensions,
  H263ErpsBufferSize? previousSize,
) {
  final commands = <H263ErpsCommand>[];
  var bufferSize = previousSize;
  int readNumber() {
    final difference = h263ErpsVlc(bits);
    if (difference >= 1024) {
      throw const FormatException('Invalid H.263+ ERPS picture number');
    }
    return (number - difference) % 1024;
  }

  while (!bits.flag()) {
    final H263ErpsOperation operation;
    H263ErpsBufferSize? size;
    var argument = 0;
    int? destination;
    String? removal;
    if (bits.flag()) {
      if (bits.flag()) {
        operation = H263ErpsOperation.removeShort;
        argument = readNumber();
      } else if (bits.flag()) {
        operation = H263ErpsOperation.assignLong;
        argument = readNumber();
        destination = h263ErpsVlc(bits);
      } else {
        operation = H263ErpsOperation.removeLong;
        argument = h263ErpsVlc(bits);
      }
    } else {
      if (!bits.flag()) {
        throw const FormatException('Invalid H.263+ ERPS buffer command');
      }
      switch (bits.read(2)) {
        case final code when code < 2:
          final shortTerm = code == 0;
          operation = shortTerm
              ? H263ErpsOperation.removeShortRegions
              : H263ErpsOperation.removeLongRegions;
          argument = shortTerm ? readNumber() : h263ErpsVlc(bits);
          final geometry = bufferSize;
          if (geometry == null) {
            throw const FormatException(
              'Missing H.263+ ERPS sub-picture geometry',
            );
          }
          final (:columns, :rows) = h263ErpsGrid(geometry, dimensions);
          removal = _readRemovalMap(bits, columns * rows);
        case 2:
          operation = H263ErpsOperation.limitLong;
          argument = h263ErpsVlc(bits);
        case 3:
          operation = H263ErpsOperation.resize;
          if (commands.isNotEmpty) {
            throw const FormatException(
              'H.263+ ERPS buffer size must come first',
            );
          }
          final width = bits.read(7) + 1, height = bits.read(7);
          final capacity = h263ErpsVlc(bits) + 1;
          if (height == 0 || height > 72) {
            throw const FormatException(
              'Invalid H.263+ ERPS sub-picture height',
            );
          }
          size = (
            width: width,
            height: height,
            capacity: capacity,
            reset: bits.flag(),
          );
          bufferSize = size;
        default:
          throw StateError('Invalid two-bit ERPS command');
      }
    }
    commands.add((
      operation: operation,
      argument: argument,
      destination: destination,
      size: size,
      removal: removal,
    ));
  }
  return commands;
}

String _readRemovalMap(Rbsp bits, int count) {
  final map = <int>[];
  var unused = 0, zeroes = 0;
  for (var i = 0; i < count; i++) {
    final bit = bits.bit();
    map.add(48 + bit);
    unused += bit;
    zeroes = bit == 0 ? zeroes + 1 : 0;
    if (zeroes == 8) {
      if (!bits.flag()) {
        throw const FormatException('Missing H.263+ ERPS bitmap marker');
      }
      zeroes = 0;
    }
  }
  if (unused == 0 || unused == count) {
    throw const FormatException('Invalid H.263+ ERPS sub-picture bitmap');
  }
  return String.fromCharCodes(map);
}

// Table U.1 interleaves the data bits with continuation bits.
int h263ErpsVlc(Rbsp bits) {
  if (bits.flag()) return 0;
  var value = 2 | bits.bit();
  var length = 1;
  while (bits.flag()) {
    if (++length > 11) {
      throw const FormatException('Oversized H.263+ ERPS VLC');
    }
    value = (value << 1) | bits.bit();
  }
  return value - 1;
}
