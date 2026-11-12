# vimg-dart

The Dart rewrite lives alongside the Rust CLI. The Dart runtime handles media
directly. The Yazi integration uses the existing external `ya` DDS client.

## Build

From this directory with Dart 3.11 or later:

```sh
dart pub get
dart compile exe bin/vimg.dart -o vimg
```

On Windows, use `-o vimg.exe`.

## Available commands

- `vimg probe video.mkv` reads Matroska/WebM and MP4/MOV metadata and prints
  vimg-compatible JSON.
- `vimg join -c3 -H160 image1.png image2.png -o grid.png` resizes images and
  composes a contact sheet. Pass a repeated `--label` to label successive tiles.

The grid uses the Dart image library's bitmap fonts. Supported image formats
depend on the library's encoders and decoders.

- `vimg preview --output preview.jpg video.mov` writes a bounded JPEG and
  returns the Yazi metadata response. It can read embedded cover art and VP8
  keyframes as well as the video codecs below.
- `vimg extract -n3 --output-dir frames video.mkv` writes sampled BMP frames.
- `vimg vcs -c3 -H160 -n9 --webp 1 video.mkv -o grid.webp` writes a still
  or animated WebP. Choose a `.jpg` output for a still JPEG contact sheet.

Extraction and contact sheets currently decode MJPEG and PNG tracks in
Matroska or unfragmented MP4/MOV. AVIF output and decoding inter-frame formats
such as H.264 and HEVC are pending. The bundled `sample/input.mkv` can be probed
and requires an H.264 decoder for extraction and contact sheets.

## Verification

```sh
dart analyze
dart test/probe_join_test.dart
dart test/video_test.dart
```
