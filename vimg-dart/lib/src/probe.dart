import 'dart:io';

import 'binary_file.dart';
import 'iso_media.dart';
import 'matroska.dart';
import 'metadata.dart';

VideoMetadata probe(String path) {
  final input = File(path).openSync();
  try {
    final file = BinaryFile(input);
    return switch (file.unsigned(0, 4)) {
      0x1a45dfa3 => Matroska(file).metadata(),
      _ => IsoMedia(file).metadata(),
    };
  } finally {
    input.closeSync();
  }
}
