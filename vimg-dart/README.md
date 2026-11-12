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

- `vimg probe video.mkv` reads Matroska/WebM, MP4/MOV and AVI metadata and prints
  vimg-compatible JSON.
- `vimg join -c3 -H160 image1.png image2.png -o grid.png` resizes images and
  composes a contact sheet. Pass a repeated `--label` to label successive tiles.

The grid uses the Dart image library's bitmap fonts. Supported image formats
depend on the library's encoders and decoders.

- `vimg preview --output preview.jpg video.mov` writes a bounded JPEG and
  returns the Yazi metadata response. It can read embedded cover art and VP8
  keyframes as well as the video codecs below.
- `vimg extract -n3 --output-dir frames video.mkv` writes sampled BMP frames.
- `vimg vcs -c3 -H160 -n9 video.mkv -o grid.avif` writes an animated AVIF.
  Pass `-f1` for a still, `--webp 1` for WebP or choose a `.jpg` output for JPEG.
- `vimg print-completions [bash|zsh|fish|powershell|elvish]` prints a completion
  script for the Dart CLI.

Extraction and contact sheets decode MJPEG and PNG tracks in Matroska,
unfragmented MP4/MOV or AVI. AVI also supports uncompressed 24-bit and 32-bit
BGR. Matroska and MP4/MOV support progressive 8-bit H.264 I/P/B pictures
with CABAC or CAVLC and 4:2:0 or monochrome chroma. `extract` and `vcs` decode
forward from the preceding IDR, reuse reference pictures for captures in the
same GOP, and select captures by presentation timestamp. `sample/input.mkv`
can be used with `preview`, `extract` and `vcs`. `preview` selects an IDR for
a quick static image. HEVC decoding is pending, along with Rust's
`authority` commands, FFmpeg filter expressions and hardware capture backends.

The pure Dart AVIF encoder uses 8-bit 4:4:4 keyframes. Each 8×8 block uses
separate palettes for green samples and blue/red pairs. Blocks with up to
eight entries per palette preserve those samples exactly. More complex blocks
are quantized, and animation uses an independent keyframe for each frame.
These choices differ from the Rust encoder's inter-frame compression and
CRF settings. The current encoder supports one AV1 Level 5.1 tile.

## Yazi DDS

Use the `gridthumb.yazi` plugin in the repository root. The service starts on
demand using the configured Dart executable and Yazi's matching `ya` client.

```lua
require("gridthumb"):setup {
    vimg = "/path/to/vimg-dart/build/vimg",
    dart_media = true,
}
```

The service logs live status, shares duplicate requests, supports interactive
cancellation, and caps running plus queued previews at ten. It runs one render
at a time by default. Set `service_args = { "--jobs", "2" }` to allow two
simultaneous renders. AVIF uses the existing DDS events. Set
`grid_format = "webp"` to request WebP on its dedicated events. Stop an already
running Rust AVIF service before using the Dart service on the same AVIF
topics. Manual use:

```sh
vimg serve --ya /path/to/ya -j2
vimg send --yazi-id 123 video.mkv /path/to/cache.avif
```

`serve` uses OS CPU scheduling. The plugin's Dart mode uses the Dart
`preview` and `probe` commands for static images and metadata.

## Verification

```sh
dart analyze
dart test/probe_join_test.dart
dart test/video_test.dart
dart test/avif_test.dart
dart test/h264_test.dart
dart test/hevc_test.dart
dart compile exe bin/vimg.dart -o build/vimg
dart compile exe test/fake_ya.dart -o build/fake-ya
dart test/service_test.dart build/vimg build/fake-ya
```

Pass an installed `dav1d` executable to `dart test/avif_test.dart` to compare
the AV1 samples from the generated AVIFs against their input pixels.
