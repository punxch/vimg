import 'metadata.dart';
import 'video.dart';

VideoMetadata probe(String path) {
  final video = Video(path);
  try {
    return video.metadata;
  } finally {
    video.close();
  }
}
