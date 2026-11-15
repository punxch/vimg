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
  AVIF inputs use the primary image, including the cover of an animation.
  The Dart reader supports coded images, tiled grids, auxiliary alpha, and
  clean aperture, rotation and mirror properties.

The grid renders labels with the embedded Cantarell font. Supported image
formats depend on the Dart image library's encoders and decoders.

- `vimg preview --output preview.jpg video.mov` writes a bounded JPEG and
  returns the Yazi metadata response. It can read embedded cover art and VP8
  keyframes as well as the video codecs below.
- `vimg extract -n3 --output-dir frames video.mkv` writes sampled BMP frames.
- `vimg vcs -c3 -H160 -n9 video.mkv -o grid.avif` writes an animated AVIF.
  Pass `-f1` for a still, `--webp 1` for WebP or choose a `.jpg` output for JPEG.
  A `.webp` output also selects WebP. Other output names default to AVIF
  unless `--webp` is set.
  `--avif-crf` runs from 0 (finest quantization) to 63 and defaults to 30.
  `--avif-preset` sets the encoder search effort from 0 (most) to 13 (least)
  and defaults to 8. The values `dart`, `libsvtav1` and `libaom-av1` for
  `--avif-codec` all select the pure Dart encoder.
- `vimg authority record -c3 -H160 -n9 --output grid.avif --manifest grid.json video.mkv`
  records the fixed Preview profile, the selected source PTS and pre-encoder
  and decoded PNGs.
- `vimg authority verify reference.avif candidate.avif --min-ssim 0.999`
  compares animation structure and every decoded frame.
- `vimg print-completions [bash|zsh|fish|powershell|elvish]` prints a completion
  script for the Dart CLI. The script queries the installed `vimg` for the
  active command's options, subcommands and allowed values. Source the Bash,
  Fish, PowerShell or Elvish script in the corresponding shell. For Zsh, save
  it as `_vimg` on `fpath` before running `compinit`.

Extraction and contact sheets decode MJPEG and PNG tracks in Matroska,
MP4/MOV or AVI. AVI also supports uncompressed indexed 1-, 4- and 8-bit
video, RGB555, 24- and 32-bit BGR and 16- and 32-bit RGB bitfields.
Matroska `V_UNCOMPRESSED`, Matroska VFW FourCC and AVI FourCC tracks
support planar YUV, grayscale and GBR, NV12/NV21, packed YUV 4:2:2
including YUY2, UYVY, Y210 and Y216, and packed RGB/BGR and RGBA.
Filters work at source sample depth. BMP capture keeps alpha where present.
QuickTime supports uncompressed RGB555, RGB24, ARGB32 and packed YCbCr
(`2vuy`, `yuv2`, `v210`, `v216`, `v308`, `v408` and `v410`).
Packed YCbCr keeps its component depth through filtering and scaling.
ARGB and `v408` retain alpha in BMP extraction.
QuickTime Animation (`rle `) supports RGB555, RGB24, ARGB32 and 1-, 2-,
4- and 8-bit indexed or grayscale frames. Extraction restores partial
updates and repeated frames from the preceding sync sample and keeps ARGB
alpha in BMPs.
QuickTime Apple Video (`rpza`) supports RGB555 blocks with solid colors,
four-color palettes, literal pixels and updates that reuse earlier blocks.
Preview and extraction locate complete pictures from the block data.
QuickTime Graphics (`smc `) supports 8-bit indexed color and grayscale,
including embedded palettes, block repeats, and differential frames.
Random access accounts for both pixel and palette dependencies.
Cinepak (`cvid`) in MOV and AVI supports color, grayscale and indexed
frames. Random access follows codebook updates and blocks retained from
earlier pictures. AVI palette changes apply to both indexed Cinepak and
indexed uncompressed video.
AVI also supports Microsoft RLE4 and RLE8, including delta runs, palette
changes and uncompressed bitmap chunks in the same track.
Microsoft Video 1 (`MSVC`, `CRAM`, `WHAM`) in AVI and Matroska supports
8-bit indexed color, RGB555 and blocks carried forward from the preceding
frame. AVI can update the palette between pictures.
HuffYUV and FFVHUFF in AVI and Matroska support fixed or stored Huffman
tables, per-frame tables, left, plane and median prediction, and interlaced
prediction. The decoder keeps native YUV and planar RGB samples through
scaling and filters, including up to 16 bits per component in FFVHUFF.
BMP extraction preserves alpha from streams that carry it.
HuffYUV MT (`HYMT`) in AVI and Matroska can reconstruct frames from
horizontal slices, restarting prediction at each slice boundary.
FFV1 versions 0, 1 and 3 in Matroska, AVI and MP4/MOV support Golomb–Rice
and range coding, YCbCr, grayscale and reversible RGB with optional alpha.
Versions 1 and 3 can retain up to 16 bits per sample, and version 3 supports
multiple slices and CRC checking. Experimental FFV1 v4 supports
chroma-aligned slices, per-slice RGB transforms, raw PCM, sample remapping
and FFmpeg's alternate CRC seed. It also decodes 16-bit floating-point
grayscale and RGB, 32-bit floating-point RGB and 16-bit RGGB Bayer.
Float previews and captures clamp channels to the display range [0, 1].
Bayer capture uses bilinear demosaicing. Random access rebuilds entropy
contexts from the preceding FFV1 keyframe.
Matroska and MP4/MOV support 8–14-bit H.264 I/P/B pictures
with CABAC or CAVLC in monochrome, 4:2:0, 4:2:2 and 4:4:4. This includes
lossless streams that use transform bypass and 4:4:4 RGB streams signaled
with an identity color matrix. The decoder handles both jointly and
independently coded 4:4:4 color planes. It also combines separately coded
top and bottom fields into full frames, including fields stored in separate
MP4 samples or MPEG transport PES packets. Picture-adaptive frame/field
coding (PAFF) can use reference pictures coded in either form.
Macroblock-adaptive frame and field coding (MBAFF) supports I, P and B slices,
including spatial and temporal direct prediction and B reference pictures.
`extract` and `vcs` decode
forward from the preceding IDR, reuse reference pictures for captures in the
same GOP, and schedule captures using the source frame durations and the
Rust CLI's constant-frame-rate selection rules. `sample/input.mkv`
can be used with `preview`, `extract` and `vcs`. `preview` selects an IDR for
a quick static image.

Matroska and MP4/MOV also support HEVC I/P/B pictures in
monochrome, 4:2:0, 4:2:2 and 4:4:4. `preview` selects an
HEVC random-access picture. `extract` and `vcs` decode from the preceding
random-access point and handle leading pictures that depend on an earlier GOP.
HEVC field sequences are decoded in either field order. Each field keeps its
own height and presentation timestamp, including in MPEG transport streams.
H.264 and HEVC tracks can update their parameter sets in band. Preview and
parallel capture restore the sets available at each random-access point.
The decoder also handles range extension streams with residual DPCM,
transform-skip rotation and CABAC contexts, persistent Rice adaptation,
cross-component prediction, coding-unit chroma QP adjustments and
high-precision weighted prediction offsets. The decoder supports up to
16-bit samples, extended transform precision and CABAC bypass alignment.
Separate colour planes and hardware capture backends remain pending.

MPEG-TS supports H.264, HEVC, MPEG-1 Video and MPEG-2 Video in 188-byte TS,
192-byte M2TS and 204-byte transport packets. Capture uses the first
supported video track found through the program tables. It groups video
access units, preserves source PTS across 33-bit rollover and accounts for
an earlier audio start in the same program. Capture workers read the
selected GOPs directly from the source file.

Standalone H.264 and HEVC Annex B streams support probe, preview, extraction
and contact sheets. Their timeline starts at zero and uses picture order and
the signalled frame rate. Streams without a signalled rate use 25 fps.

AVI also supports H.264 and HEVC chunks with Annex B start codes or a
length-prefixed codec configuration. Presentation uses the AVI sample clock
and the bitstream's picture order. Empty chunks leave gaps in the clock.

Matroska, MP4/MOV, MPEG-TS, MPEG-PS and elementary `.m1v`/`.m2v` streams
support MPEG-1 and MPEG-2 I/P/B pictures. MP4/MOV can supply the sequence
headers in the video samples, an `esds` descriptor or a QuickTime `glbl`
box. Both conventional and fragmented MP4 files work. MPEG-2 supports
progressive and interlaced frame pictures and separately coded top and bottom
fields. The decoder pairs fields in either order and reconstructs one frame.
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
H.264 and HEVC with missing PES timestamps use the bitstream's picture order
and frame cadence to infer presentation times. Fully untimed video starts at
zero when the bitstream provides a frame rate. Scalable MPEG-2 and DVD title
navigation remain pending.

Matroska and WebM capture apply the selected track's pixel crop and rectangular
projection roll or mirror before user filters and tile sizing.

`preview`, `extract` and `vcs` decode AV1 from Matroska, MP4 and IVF. IVF
uses packet timestamps to derive playback duration and retains coded order
for reference pictures. IVF also supports VP8 keyframe previews, extraction
from all-intra VP8 streams and VP9 metadata probing. The
AVIF animation reader handles intra and inter pictures, including hidden
references, reused pictures, compound prediction, warped motion, deblocking,
CDEF, horizontal super-resolution, Wiener and SGRPROJ loop restoration, and
intra block copy for screen content.
Film grain synthesis runs on AV1 display frames before RGB conversion.

MP4/MOV and Matroska support Apple ProRes 422 and 4444, including Proxy,
LT, HQ and XQ. The decoder handles progressive frames and both interlaced
field orders. BMP extraction, including `vcs --keep`, retains 8-bit or 16-bit
source alpha as an 8-bit BMP alpha channel. ProRes RAW remains pending.

MP4/MOV files can contain conventional sample tables, movie fragments, or both.
Preview, extraction, and contact sheets apply the selected track and movie
display matrices before user filters and tile sizing. Quarter turns and mirrors
keep the decoded sample values. Other angles use a fixed-size canvas with
bilinear interpolation and black fill.
Fragmented files use a local initialization movie and local media data. Probe
derives duration from the track runs when the initialization has zero duration.
Capture uses the edited playback timeline and preserves raw container PTS in
the authority manifest. Preview and capture switch sample descriptions at
random-access pictures, including when the track switches between supported
codecs. Probe reports the first description in use. Contact sheets center
each image in a tile of fixed dimensions and preserve its aspect ratio when
the source geometry changes. When fragment decode times overlap, samples at or
before the preceding run's last decode time are still available as references
and are skipped during presentation. Encrypted tracks remain pending.

`extract` and `vcs` accept a comma-separated `--vfilter` chain such as
`--vfilter 'crop=iw/2:ih,transpose=clock,hflip'`. The Dart filters include
`crop`, `scale`, `pad`, `drawbox`, `negate`, `setsar`, `setdar`, `hflip`,
`vflip`, `transpose` and `null`. Crop and scale
accept static dimension expressions with arithmetic and functions such as
`min`, `max` and `trunc`. Scale supports `flags=bicubic` (default), `bilinear`,
`bicublin` and `neighbor`. `bicublin` scales luma and alpha with a bicubic
kernel and YUV chroma with a bilinear kernel. Crop aligns to chroma samples by
default and accepts `exact=1` for odd coordinates and dimensions.

Use `scale=400:300:force_original_aspect_ratio=decrease:force_divisible_by=2`
to fit inside a bounding box with even dimensions. `increase` scales to cover
the box. Add `reset_sar=1` to use the input display aspect ratio for
proportional scaling and set square pixels for downstream filters.

For packed RGB, `neighbor`, `bilinear` and `bicublin` use FFmpeg's paired chroma
sampling when reducing an even width by at least half. Add `+full_chroma_inp`
to sample the RGB channels at full resolution.
RGB conversion after spatial filters interpolates subsampled chroma at odd
widths and keeps full-resolution chroma for 4:4:4 input.

Crop coordinates accept frame number `n` and timestamp `t` in seconds.
Scale accepts these variables in its dimensions with `eval=frame`.
As in FFmpeg 8, the first frame has `n=0` in crop and `n=1` in scale.
`--vfilter 'crop=iw/2:ih:min(n*2,iw/2):0'` pans across the frame.

For example, `--vfilter 'pad=iw+32:ih+32:-1:-1:black,drawbox=8:8:64:40:yellow@0.5:3'`
adds a centered border and draws a translucent box. Colors accept named
values, RGB/RGBA hex and explicit opacity. `negate=components=y+u`
inverts selected planes. `setsar` and `setdar` affect aspect expressions
such as `pad=aspect=16/9`. Filters read sample aspect from the active MP4/MOV
`pasp` entry or Matroska display dimensions, with H.264 and HEVC sequence
parameters as a fallback. Capture size limits use pixel dimensions.
On deeper sources, `drawbox` retains native depth.

Timing filters include `trim`, `setpts`, `settb` and `fps`. They run for
each seek window before conversion to the requested capture rate. For example,
`--vfilter 'trim=start=0.25,setpts=PTS-STARTPTS,fps=15'` skips the first
quarter-second of each window and restarts its filtered timestamps at zero.
`trim` accepts time, PTS and frame-count limits. `setpts` accepts deterministic
expressions over timestamps, frame counts and rates. `settb` changes the
time base, and `fps` supports start padding, rounding and EOF modes. Spatial
expressions use the timeline at their position in the chain. A crop after
`fps` sees the duplicated frames, and a crop before `fps` sees the
original frames. Wall-clock expressions, expressions that depend on earlier
spatial evaluations, and branched graphs are pending.

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
motion at the default preset and reuse reconstructed frames for repeats.
Lower presets search a wider motion range and compare more intra predictions
on still images and keyframes. Presets 12–13 search integer motion only.
Dart maps `--avif-crf`
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
dart test/video_paint_filters_test.dart
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
dart test/iso_mpeg_test.dart
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
