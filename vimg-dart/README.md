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

- `vimg probe video.mkv` reads Matroska/WebM, MP4/MOV, AVI, MPEG-TS,
  MPEG-PS and standalone MPEG video metadata and prints vimg-compatible JSON.
- `vimg join -c3 -H160 image1.png image2.png -o grid.png` resizes images and
  composes a contact sheet. Pass a repeated `--label` to label successive tiles.

The grid renders labels with the embedded Cantarell font. Supported image
formats depend on the Dart image library's encoders and decoders.

- `vimg preview --output preview.jpg video.mov` writes a bounded JPEG and
  returns the Yazi metadata response. It can read embedded cover art and VP8
  keyframes as well as the video codecs below.
- `vimg extract -n3 --output-dir frames video.mkv` writes sampled BMP frames.
- `vimg vcs -c3 -H160 -n9 video.mkv -o grid.avif` writes an animated AVIF.
  Pass `-f1` for a still, `--webp 1` for WebP or choose a `.jpg` output for JPEG.
  `--avif-crf` runs from 0 (finest quantization) to 63 and defaults to 30.
- `vimg authority record -c3 -H160 -n9 --output grid.avif --manifest grid.json video.mkv`
  records the fixed Preview profile, the selected source PTS and pre-encoder
  and decoded PNGs.
- `vimg authority verify reference.avif candidate.avif --min-ssim 0.999`
  compares animation structure and every decoded frame.
- `vimg print-completions [bash|zsh|fish|powershell|elvish]` prints a completion
  script for the Dart CLI.

Extraction and contact sheets decode MJPEG and PNG tracks in Matroska,
MP4/MOV or AVI. AVI also supports uncompressed 24-bit and 32-bit
BGR. Matroska and MP4/MOV support progressive 8-bit H.264 I/P/B pictures
with CABAC or CAVLC and 4:2:0 or monochrome chroma. `extract` and `vcs` decode
forward from the preceding IDR, reuse reference pictures for captures in the
same GOP, and schedule captures using the source frame durations and the
Rust CLI's constant-frame-rate selection rules. `sample/input.mkv`
can be used with `preview`, `extract` and `vcs`. `preview` selects an IDR for
a quick static image.

Matroska and MP4/MOV also support progressive HEVC I/P/B pictures in 4:2:0
or monochrome, up to 12 bits. `preview` selects an HEVC random-access
picture. `extract` and `vcs` decode from the preceding random-access point
and handle leading pictures that depend on an earlier GOP.

MPEG-TS supports H.264, HEVC, MPEG-1 Video and MPEG-2 Video in 188-byte TS,
192-byte M2TS and 204-byte transport packets. Capture uses the first
supported video track found through the program tables. It groups video
access units, preserves source PTS across 33-bit rollover and accounts for
an earlier audio start in the same program. Capture workers read the
selected GOPs directly from the source file.

Matroska, MPEG-TS, MPEG-PS and elementary `.m1v`/`.m2v` streams support
MPEG-1 and MPEG-2 I/P/B pictures. MPEG-2 supports progressive and interlaced
frame pictures as well as separately coded top and bottom fields. Field
pictures are paired in either field order and reconstructed into one frame.
Field motion compensation includes 16×8 and dual-prime prediction.
Capture handles B-pictures that depend on an earlier GOP and selects
I-frames, including I/P field pairs, for static previews. MPEG transport
streams can retain complete pictures before a truncated final video PES.
When MPEG-1 or
MPEG-2 PES packets omit some picture timestamps, capture reconstructs
presentation order from the GOP and picture headers. Elementary streams
start at zero and use sequence timing, including signalled repeated fields.

Program streams include MPEG-1 `.mpg`, MPEG-2 `.mpg` and unencrypted DVD
`.vob` files. Program timing accounts for MPEG audio and DVD AC-3, DTS
and LPCM tracks. A program stream map can also identify H.264 or HEVC.
Scalable MPEG-2, DVD title navigation and reordered H.264 or HEVC pictures
without usable timestamps remain pending.

`preview`, `extract` and `vcs` decode AV1 from Matroska and MP4. The
AVIF animation reader handles intra and inter pictures, including hidden
references, reused pictures, compound prediction, warped motion, deblocking,
CDEF, horizontal super-resolution, Wiener and SGRPROJ loop restoration, and
intra block copy for screen content.
Film grain synthesis runs on AV1 display frames before RGB conversion.
HEVC range extension tools and hardware capture backends remain pending.

MP4/MOV and Matroska support Apple ProRes 422 and 4444, including Proxy,
LT, HQ and XQ. The decoder handles progressive frames and both interlaced
field orders. BMP extraction, including `vcs --keep`, retains 8-bit or 16-bit
source alpha as an 8-bit BMP alpha channel. ProRes RAW remains pending.

MP4/MOV files can contain conventional sample tables, movie fragments, or both.
Fragmented files use a local initialization movie and local media data. Probe
derives duration from the track runs when the initialization has zero duration.
Capture uses the edited playback timeline and preserves raw container PTS in
the authority manifest. Encrypted tracks, overlapping or out-of-order
fragments, and changes of sample description are pending.

`extract` and `vcs` accept a comma-separated `--vfilter` chain such as
`--vfilter 'crop=iw/2:ih,transpose=clock,hflip'`. The Dart filters include
`crop`, `scale`, `hflip`, `vflip`, `transpose` and `null`. Crop and scale
accept static dimension expressions with arithmetic and functions such as
`min`, `max` and `trunc`. Scale supports `flags=bicubic` (default) and
`flags=neighbor`. Crop aligns to chroma samples by default and accepts
`exact=1` for odd coordinates and dimensions.

Timing filters include `trim`, `setpts`, `settb` and `fps`. They run for
each seek window before conversion to the requested capture rate. For example,
`--vfilter 'trim=start=0.25,setpts=PTS-STARTPTS,fps=15'` skips the first
quarter-second of each window and restarts its filtered timestamps at zero.
`trim` accepts time, PTS and frame-count limits. `setpts` accepts deterministic
expressions over timestamps, frame counts and rates. `settb` changes the
time base, and `fps` supports start padding, rounding and EOF modes. Wall-clock
expressions, frame-dependent spatial expressions and branched graphs are pending.

`vcs` applies the requested tile size after the filter chain and lays out the
grid using the resulting tile dimensions. With `--keep`, it saves the filtered
BMPs before tile resizing. Authority recording uses the fixed Preview profile.

The authority manifest identifies the capture backend as
`production-dart-capture`. Its `input_frame_index` is the zero-based index
in the presentation timeline used for Dart capture. The source PTS is
stored as integer ticks with a rational time base, before applying playback edits.

`extract`, `vcs`, and `authority record` accept `-T` / `--threads`. The default
is 4 capture workers. `-T0` uses available CPUs and `-T1` decodes serially.
Workers share the capture schedule and decode independent runs of pictures.

Contact sheet AVIFs use the pure Dart 10-bit 4:2:0 encoder with DCT residuals.
Animated sheets search the preceding reconstructed frame for quarter-pixel
motion and reuse reconstructed frames for repeats. Dart maps `--avif-crf`
to its own AV1 quantizers. `join` uses the 8-bit 4:4:4 palette encoder for
still AVIF images. Both encoders support one AV1 Level 5.1 tile.

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
dart test/video_filters_test.dart
dart test/video_timing_test.dart
dart test/capture_test.dart
dart test/avif_test.dart
dart test/av1_header_test.dart
dart test/av1_intra_test.dart
dart test/av1_intrabc_test.dart
dart test/av1_inter_test.dart
dart test/av1_restoration_test.dart
dart test/av1_superres_test.dart
dart test/av1_film_grain_test.dart
dart test/av1_coefficients_test.dart
dart test/av1_transform_test.dart
dart test/h264_test.dart
dart test/hevc_test.dart
dart test/iso_fragments_test.dart
dart test/transport_stream_test.dart
dart test/mpeg_video_test.dart
dart test/mpeg_fields_test.dart
dart test/program_stream_test.dart
dart test/prores_test.dart
dart test/authority_test.dart
dart compile exe bin/vimg.dart -o build/vimg
dart compile exe test/fake_ya.dart -o build/fake-ya
dart test/service_test.dart build/vimg build/fake-ya
```

Pass an installed `dav1d` executable to `dart test/avif_test.dart` to compare
the AV1 samples from the generated AVIFs against their input pixels.
