# vimg-dart

The Dart rewrite lives alongside the Rust CLI. The Dart runtime handles media
directly. The Yazi integration uses the existing external `ya` DDS client.

## Build

From this directory with Dart 3.11 or later:

```sh
dart pub get
mkdir build
dart compile exe bin/vimg.dart -o build/vimg
```

On Windows, use `-o build/vimg.exe`.

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
- `vimg print-completions [bash|zsh|fish|powershell|elvish]` prints a completion
  script for the Dart CLI.

Extraction and contact sheets currently decode MJPEG and PNG tracks in
Matroska or unfragmented MP4/MOV. AVIF output and decoding inter-frame formats
such as H.264 and HEVC are pending. The bundled `sample/input.mkv` can be probed
and requires an H.264 decoder for extraction and contact sheets. The Rust
`authority` commands, FFmpeg filter expressions, and native hardware capture
backends are also pending.

## Yazi DDS

Use the `gridthumb.yazi` plugin in the repository root and select WebP in its
setup. The service starts on demand using the configured executable and Yazi's
matching `ya` client.

```lua
require("gridthumb"):setup {
    vimg = "/path/to/vimg-dart/build/vimg",
    grid_format = "webp",
}
```

The service logs live status, shares duplicate requests, supports interactive
cancellation, and caps running plus queued previews at ten. It runs one render
at a time by default. Set `service_args = { "--jobs", "2" }` to allow two
simultaneous renders. The Dart service uses WebP-specific DDS events and the
plugin displays the WebP cache through Yazi. Manual use:

```sh
vimg serve --ya /path/to/ya -j2
vimg send --yazi-id 123 video.mkv /path/to/cache.webp
```

`serve` uses OS CPU scheduling. The WebP mode in the plugin uses the Dart
`preview` and `probe` commands for static images and metadata.

## Verification

```sh
dart analyze
dart test/probe_join_test.dart
dart test/video_test.dart
dart compile exe bin/vimg.dart -o build/vimg
dart compile exe test/fake_ya.dart -o build/fake-ya
dart test/service_test.dart build/vimg build/fake-ya
```
