import 'dds.dart';
import 'service.dart';
import 'video_cli.dart';

final class ServeCommand extends VimgCommand {
  ServeCommand() {
    argParser
      ..addOption('ya', defaultsTo: 'ya', help: 'Path to the Yazi DDS client.')
      ..addOption(
        'jobs',
        abbr: 'j',
        defaultsTo: '1',
        help: 'Concurrent preview jobs (1–10).',
      )
      ..addOption(
        'capture-backend',
        defaultsTo: 'auto',
        allowed: ['auto', 'dart'],
      )
      ..addOption(
        'cpu-policy',
        defaultsTo: 'auto',
        allowed: ['auto', 'all'],
        help: 'Use the operating system CPU scheduler.',
      );
  }

  @override
  String get name => 'serve';
  @override
  String get description => 'Run the Yazi DDS preview service.';

  @override
  Future<void> run() {
    if (argResults!.rest.isNotEmpty)
      usageException('serve takes no file arguments.');
    return serve(argResults!.option('ya')!, integer('jobs', min: 1, max: 10)!);
  }
}

final class SendCommand extends VimgCommand {
  SendCommand() {
    argParser
      ..addOption('ya', defaultsTo: 'ya', help: 'Path to the Yazi DDS client.')
      ..addOption('yazi-id', help: 'Yazi instance to receive the result.')
      ..addOption('source-size')
      ..addOption('source-modified-s')
      ..addOption('duration-s')
      ..addOption('width')
      ..addOption('height')
      ..addOption('codec')
      ..addOption('source-time-base-numerator')
      ..addOption('source-time-base-denominator');
  }

  @override
  String get name => 'send';
  @override
  String get description => 'Submit a preview request to the DDS service.';

  @override
  Future<void> run() {
    final args = argResults!;
    if (args.rest.length != 2)
      usageException('Provide a video path and a cache path.');
    final recipient = args.option('yazi-id');
    if (recipient != null && !validYaziId(recipient))
      usageException('Invalid --yazi-id.');
    final seconds = args.option('duration-s');
    final duration = seconds == null ? null : double.tryParse(seconds);
    if (seconds != null &&
        (duration == null || !duration.isFinite || duration <= 0)) {
      usageException('--duration-s must be positive.');
    }
    final event = GridFormat.fromCache(args.rest[1]).topic(DdsEvent.request);
    return publishDds(args.option('ya')!, '0', event, {
      'file': args.rest[0],
      'cache': args.rest[1],
      'yazi_id': recipient,
      'source_size': integer('source-size'),
      'source_modified_s': integer('source-modified-s'),
      'duration_s': duration,
      'width': integer('width', min: 1),
      'height': integer('height', min: 1),
      'codec': args.option('codec'),
      'source_time_base_numerator': integer(
        'source-time-base-numerator',
        min: 1,
      ),
      'source_time_base_denominator': integer(
        'source-time-base-denominator',
        min: 1,
      ),
    });
  }
}
