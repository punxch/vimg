import 'dart:io';

/// Stage output beside its destination so publishing uses a single rename.
void publishBytes(String path, List<int> bytes) {
  final target = File(path).absolute;
  final temporary = target.parent.createTempSync('.vimg-');
  try {
    final staged = File.fromUri(temporary.uri.resolve('output'));
    staged.writeAsBytesSync(bytes);
    staged.renameSync(target.path);
  } finally {
    temporary.deleteSync(recursive: true);
  }
}
