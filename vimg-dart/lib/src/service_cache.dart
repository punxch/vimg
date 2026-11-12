import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'capture.dart';
import 'output.dart';
import 'preview_queue.dart';
import 'video_commands.dart';

const _profile = 'vimg-dart-webp-3x3-h160-n9-f30-q75-v1';

Future<bool> renderPreview(PreviewJob job) => Isolate.run(() => _render(job));

bool _render(PreviewJob job) {
  if (!job.cache.toLowerCase().endsWith('.webp')) {
    throw UnsupportedError('Dart service requires a .webp cache path');
  }
  final target = File(job.cache).absolute;
  final source = File(job.file).absolute;
  final snapshot = _source(source, job);
  if (target.existsSync() &&
      FileSystemEntity.identicalSync(source.path, target.path)) {
    throw const FormatException('Cache must differ from video source');
  }
  final manifest =
      '${target.path}.${snapshot.size}-${snapshot.modifiedSeconds}.json';
  if (!job.refresh && _current(target, manifest, snapshot)) return true;

  target.parent.createSync(recursive: true);
  final staging = target.parent.createTempSync('.vimg-preview-');
  try {
    final staged = File.fromUri(staging.uri.resolve('preview.webp'));
    writeContactSheet(
      source.path,
      staged.path,
      const CaptureOptions(number: 9, frames: 30),
      columns: 3,
      height: 160,
    );
    if (_source(source, job) != snapshot) {
      throw const FormatException('Video changed during rendering');
    }
    staged.renameSync(target.path);
    publishBytes(
      manifest,
      utf8.encode(jsonEncode(_manifest(target, snapshot))),
    );
    return false;
  } finally {
    staging.deleteSync(recursive: true);
  }
}

typedef _Snapshot = ({
  String path,
  int size,
  int modifiedSeconds,
  int modifiedMicros,
});

_Snapshot _source(File file, PreviewJob job) {
  final stat = file.statSync();
  if (stat.type != FileSystemEntityType.file) {
    throw FileSystemException('Preview source is not a file', file.path);
  }
  final micros = stat.modified.microsecondsSinceEpoch;
  final seconds = micros ~/ Duration.microsecondsPerSecond;
  if ((job.sourceSize != null && job.sourceSize != stat.size) ||
      (job.sourceModified != null && job.sourceModified != seconds)) {
    throw const FormatException('Preview source changed since the request');
  }
  return (
    path: file.resolveSymbolicLinksSync(),
    size: stat.size,
    modifiedSeconds: seconds,
    modifiedMicros: micros,
  );
}

Map<String, Object> _manifest(File target, _Snapshot source) {
  final output = target.statSync();
  return {
    'profile': _profile,
    'source_path': source.path,
    'source_size': source.size,
    'source_modified_s': source.modifiedSeconds,
    'source_modified_us': source.modifiedMicros,
    'output_size': output.size,
    'output_modified_us': output.modified.microsecondsSinceEpoch,
  };
}

bool _current(File target, String manifest, _Snapshot source) {
  try {
    final stored = jsonDecode(File(manifest).readAsStringSync());
    if (stored is! Map<String, Object?>) return false;
    final expected = _manifest(target, source);
    if (stored.length != expected.length ||
        !expected.entries.every((field) => stored[field.key] == field.value)) {
      return false;
    }
    final file = target.openSync();
    try {
      final header = file.readSync(12);
      return header.length == 12 &&
          ascii.decode(header.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
          ascii.decode(header.sublist(8), allowInvalid: true) == 'WEBP';
    } finally {
      file.closeSync();
    }
  } on FormatException {
    return false;
  } on FileSystemException {
    return false;
  }
}
