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
depend on the library's encoders and decoders. AVIF support and video decoding
are pending.

## Verification

```sh
dart analyze
dart test/probe_join_test.dart
```
