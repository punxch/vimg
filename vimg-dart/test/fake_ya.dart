import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final environment = Platform.environment;
  switch (args.firstOrNull) {
    case 'sub':
      final input = File(environment['VIMG_TEST_DDS_INPUT']!);
      final topics = args[1].split(',').toSet();
      var read = 0;
      while (true) {
        final lines = input.readAsStringSync().split('\n');
        for (; read < lines.length - 1; read++) {
          if (topics.contains(lines[read].split(',').first))
            stdout.writeln(lines[read]);
        }
        await stdout.flush();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    case 'pub-to':
      final output = File(
        environment['VIMG_TEST_DDS_OUTPUT']!,
      ).openSync(mode: FileMode.append);
      try {
        output.lockSync(FileLock.blockingExclusive);
        output.setPositionSync(output.lengthSync());
        output.writeStringSync(
          '${jsonEncode([args[1], args[2], jsonDecode(args[4])])}\n',
        );
      } finally {
        output.closeSync();
      }
    default:
      exitCode = 64;
  }
}
