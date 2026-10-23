# vimg
CLI for video images. Generate animated video contact sheets fast.
Uses _ffmpeg_.

![](https://raw.githubusercontent.com/alexheretic/vimg/main/bbb.540p.avif)

### Command: vcs
Create a new contact sheet for a video.

Extracts capture frames and joins into sheet(s) then encodes into an animated, or static, vcs avif.

```
vimg vcs [OPTIONS] -c <COLUMNS> -H <CAPTURE_HEIGHT> -n <NUMBER> <VIDEO>
```

See [examples](examples.md).

### Command: extract
Extract capture bmp images from a video using ffmpeg.

```
vimg extract [OPTIONS] -n <NUMBER> <VIDEO>
```

### Command: join
Join same-sized capture images into a single grid image.

```
vimg join [OPTIONS] --columns <COLUMNS> --output <OUTPUT> <CAPTURE_IMAGES>...
```

### Command: serve

Run the long-lived preview service used by `gridthumb.yazi`:

```sh
vimg serve --capture-backend auto
```

On a cache miss, the plugin first shows a static keyframe, then requests the
animated grid. Static extraction uses one software decoding thread to avoid
hardware-device startup for a single frame; the service uses its selected backend.
On an empty static cache, builds with `in-process-decode` use `vimg preview` to
probe, seek, scale and encode JPEG in one process, with one input open and full
stream discovery. The native path covers a single progressive 8-bit YUV420
H.264/HEVC stream in Matroska or MP4/MOV without autorotation. Cover art, ambiguous
stream selection, discontinuous timestamps and unsupported formats retain the
FFmpeg path and reuse the already-probed metadata.

The native path first seeks to an indexed keyframe at or after the requested
position. It still sends earlier packets to the decoder for parameter processing,
while suppressing picture reconstruction when their PTS is known. If that attempt
fails, it creates a fresh decoder and tries the preceding indexed keyframe once.
Static previews may therefore select a different frame, including an earlier frame
near EOF; preview bounds, JPEG quality and autorotation behavior are preserved.

For large, subtitle-rich Matroska indexes, a bounded Cues reader installs the
complete video index after full stream discovery. This avoids allocating the
subtitle indexes for a single image. Unsupported layouts or inconsistent indexes
retain FFmpeg's normal parser and seek behavior.

Confirmed H.264 IDR and single-layer HEVC IDR/BLA/CRA access units can drain the
decoder immediately, avoiding extra GOP reads to release the preview frame.
NAL boundaries, picture structure and decoded output are checked. Unknown framing,
configuration changes and recovery-point H.264 pictures keep normal draining;
invalid or unsupported output retains the metadata-based FFmpeg fallback.

HEVC source frames with at least 2,073,600 pixels (1080p area) use four slice
threads and skip loop filtering (deblocking and SAO) when every hvcC PPS enables
WPP without tiles. Pixels can differ while size and JPEG quality settings stay
the same. H.264, smaller frames, streams without WPP and unknown configurations
retain filtering and one decoder thread: those cases did not show stable latency
gains from the experimental options. These settings apply only to static
previews; VCS decoding retains its own policy.

`vimg preview --output <cache> --skip 0 --max-width 600 --max-height 900 --quality 75 <video>`
prints metadata plus `native_preview` and `preview_written` flags. A successful
JSON response with `preview_written: false` requires fallback, or an upper-bound
seek refresh when `preview_upper_bound` is present. Images are encoded in memory
and published by renaming a completed file in the cache directory.

Add `--timings` to diagnose native preview latency. One `vimg-preview-timing`
JSON line on stderr reports milliseconds for opening, stream discovery, seeking,
reading/decoding, scaling, JPEG encoding and publishing; stdout keeps the same
metadata protocol. `total_ms` covers native preparation and input cleanup, not
process startup or response serialization. Failed or unsupported inputs may
report only the stages reached. Timings are disabled by default and are only
available in builds with `in-process-decode`.
The counters include `packets`, `key_packets`, `pre_target_packets` and
`early_drain`. `target_pts` and `selected_pts` use the video stream's time base;
`seek_mode` and `attempts` describe the final seek path and total attempts.
`cue_index_entries` and `cue_index_points` report installed video entries and
inspected CuePoints when the large-index fast path is used.
`drain_kind` identifies early H.264 IDR or HEVC IDR/BLA/CRA draining, otherwise null.
`decoder_threads` and `skip_loop_filter` report the last opened decoder's policy.
Stage names can repeat after a retry; sum repeated stages when aggregating timings.

Existing static images skip extraction. Their metadata, and installations too old
for `preview`, use `vimg probe <video>` or ffprobe. Standard builds report the
missing native capability without starting ffprobe inside `preview`. The plugin
caches unavailable capabilities for the Yazi session; per-file failures do not
disable other files. Update both the executable and plugin, then restart Yazi to
use the combined path.

The plugin publishes `vimg-gridthumb-request` messages through Yazi DDS. The
service receives them with `ya sub`, runs the equivalent of
`vimg vcs -c3 -H160 -n9 <video> --output <file-cache>.avif` in-process, and
publishes `gridthumb-avif-ready` back to the requesting Yazi instance with
`ya pub-to`. Duplicate cache requests share one job. By default, one preview
runs while up to nine wait; the newest queued preview runs next. At capacity,
a new request replaces the oldest queued job, preserving jobs already running.
Use `vimg serve --jobs 4` (or `-j4`) to increase concurrent previews when batch
throughput matters more than first-preview latency and memory use. `--jobs`
accepts 1 through 10; running and queued jobs together remain capped at ten.
If all ten are already running, a new distinct request receives `busy`.

The plugin marks requests with `latest: true`. Each Yazi instance then keeps
one current preview interest: switching previews removes its previous interest,
and a queued job with no remaining requester is removed. Hovering another file
or switching tabs also sends `vimg-gridthumb-cancel` with the previous `cache`,
including when the new file already has a cache or needs no video preview.
Running jobs finish and populate their caches. Shared requests from other
instances and ordinary requests without `latest` remain intact; `vimg send`
keeps its batch behavior. Interactive interest and cancellation use the DDS
sender ID, and cancellation only matches that sender's current cache.
When a result is ready, the plugin forces a preview refresh for the hovered
file while preserving its current preview position.

With the native backend on Windows hybrid CPUs, `serve --cpu-policy auto`
(the default) selects the performance cores to keep idle-service preview
latency stable. Core types come from Windows; existing process affinity or
process-default CPU Sets are preserved. Homogeneous CPUs, multiple processor
groups, other platforms and explicit `--capture-backend ffmpeg` keep OS scheduling. Use
`vimg serve --cpu-policy all` to keep all allowed cores available, for example
when comparing throughput for batches. This policy only affects the service;
standalone `vimg vcs` commands keep OS scheduling.

Copy [`gridthumb.yazi`](gridthumb.yazi) into Yazi's plugin directory and call
`require("gridthumb"):setup()` from `init.lua`. `vimg send` remains available
as a command-line DDS publisher for diagnostics and compatibility.

### Measure resident previews on Windows

Build release tests with `cargo test --release --features in-process-decode --no-run`,
then pass the resulting test executable to the benchmark:

```powershell
python scripts/bench-service.py --test-exe target/release/deps/vimg-<hash>.exe --dll-dir D:/ffmpeg-dev/libav-deploy --output-dir .scratch/service-budget --jobs-per-process 50 --max-p95-seconds 1.3 --max-peak-mb 512
```

Use your libav DLL directory and a new output directory for each run. The script
compares immediate jobs with jobs started after ten seconds of process idle time,
records phase timings and CPU/memory observations, and verifies repeated output
and cache reuse. Each process must meet the requested warm P95 and observed peak
working-set budgets; MB means 1,000,000 bytes. Exit 2 reports a budget violation
or relative slowdown. Results exclude DDS transport and do not measure a cold
disk cache. Omitting the absolute budgets checks only relative slowdown.
The summary groups warm jobs by observed other-process CPU use (below 30%,
30% to below 45%, and 45% or higher), with sample counts and phase timings.
These groups help interpret noisy runs; all jobs still count toward acceptance,
and a small group's P95 is not a reliable latency guarantee.

## Install

### Minimal native Windows runtime

Build the executable with FFmpeg 8.1.2 development libraries, then build and
package a small `avfilter` alongside the existing codec/container libraries:

```powershell
$env:PKG_CONFIG_PATH='D:/ffmpeg-dev/ffmpeg-8.1.2-full_build-shared/lib/pkgconfig'
cargo build --profile preview --features in-process-decode
python -B -X utf8 scripts/build-preview-runtime.py --exe target/preview/vimg.exe --runtime-dir D:/ffmpeg-dev/libav-deploy --output-dir target/preview-runtime
```

The Cargo `preview` profile inherits release settings and optimizes Rust code
for a smaller executable and fresh-process startup. All subcommands remain
available. The standard `cargo build --release` profile is also supported.

This Windows x64 script requires Python 3.12+, Git Bash, MinGW GCC/make and NASM;
use `--bash`, `--mingw-bin` and `--nasm` to override the tool paths. It verifies the
pinned source SHA-256 and runtime library versions, disables linker timestamps,
records build inputs and file hashes in `manifest.json`, and keeps the source/build cache in
`target/preview-ffmpeg`. The output directory must be new. To package a previously
built minimal DLL independently, add `--filter-dll <path/to/avfilter-11.dll>`;
the same library-version and filter-set checks still apply. An `INCOMPLETE` marker
indicates a failed package check. Nothing is installed globally.

Only `avfilter` is replaced. It retains `buffer`, `buffersink`, `scale`, `format`
and the always-built audio buffer endpoints; all supplied codec, container and
other runtime DLLs are copied unchanged, including the SVT-AV1 capability.
Run `target/preview-runtime/vimg.exe` to use the adjacent DLLs. Build provenance
and performance measurements are recorded in [report.md](report.md).

Validate preview behavior and compare warm, fresh-process release latency with:

```powershell
python -B -X utf8 scripts/test-preview-fast.py --vimg target/preview-runtime/vimg.exe --fixtures .scratch/startup/preview-fixtures --output-dir .scratch/startup/preview-check
python -B -X utf8 scripts/test-preview-cues.py --vimg target/preview-runtime/vimg.exe --fixtures .scratch/startup/cue-fixtures --output-dir .scratch/startup/cue-check
python -B -X utf8 scripts/bench-static-preview.py --baseline <old-vimg.exe> --candidate target/preview-runtime/vimg.exe --video sample/input.mkv --output-dir .scratch/startup/preview-bench
python -B -X utf8 scripts/test-preview-decode.py --baseline <old-vimg.exe> --candidate target/preview-runtime/vimg.exe --fixtures .scratch/startup/decode-fixtures --output-dir .scratch/startup/decode-check sample/input.mkv
```

Put FFmpeg/ffprobe on PATH for image checks and full runtime DLLs on PATH for the
baseline. Each benchmark arm receives two warmups and twelve measured calls in
ABBA/BAAB order, with new output files. Add `--timings` for a separate diagnostic
run. This benchmark does not purge the Windows file cache; the RAMMap/ETW cold
measurement procedure and evidence are described in the report. Static tests
record JPEG/RGB differences and require complete decoding, dimensions, metadata
and fallback behavior; `test-static-preview.py --exact` optionally checks the old
image for diagnostics. VCS frame/timeline checks remain unchanged.
The decoder comparison checks selected timestamps, actual thread counts, dimensions
and complete JPEG decoding, and records RGB error/PSNR for visual inspection.
Its optional fixtures cover WPP, disabled WPP, multiple slices and small frames;
fixture hashes are checked before reuse.

On Windows, add `--max-system-cpu 12 --idle-system-cpu 8` to the warm benchmark
to wait for one second of low CPU load before each measured call. A busy call
causes its entire four-call ABBA/BAAB block to be retained and repeated. The JSON
contains both the accepted-block `summary` and `all_samples_summary`; `rows.json`
keeps every measurement and its acceptance status. `--max-blocks` and
`--idle-timeout` bound retries and idle waits. Set these limits before a run;
compare each complete group of measurements separately.

With `--timings`, both summaries also include `stage_distributions_ms` (median,
P95, minimum and maximum per stage), `native_total_ms`, and `outside_native_ms`.
The existing `stages_ms` medians remain available. The outside-native remainder
is wall time minus the reported native span; it includes process creation,
loading, CLI work, output and exit, so it must not be labeled DLL loading time.

### Arch Linux
Available in the [AUR](https://aur.archlinux.org/packages/vimg).

### Windows
Pre-built **vimg.exe** included in the [latest release](https://github.com/alexheretic/vimg/releases/latest).

### Using cargo
Latest release
```sh
cargo install vimg
```

Latest code direct from git
```sh
cargo install --git https://github.com/alexheretic/vimg
``` 

### Requirements
**ffmpeg** that's not too old should be in `$PATH`.

### Optional: in-process decoding

The default build requires only the `ffmpeg` executable. An optional build
capability enables faster in-process decoding through ffmpeg's libav
libraries:

```sh
cargo install vimg --features in-process-decode
```

This adds **libav development libraries** as a build-time dependency
(`libavcodec-dev`, `libavformat-dev`, `libavfilter-dev`, `libavutil-dev`,
`libswscale-dev` on Debian/Ubuntu; installed automatically with `brew install
ffmpeg` on macOS). The runtime still requires the `ffmpeg` executable as a
fallback.

## Capture Backends

Vimg supports multiple capture backends for frame extraction. The backend is
selected with `--capture-backend`:

| Policy | Behavior |
|--------|----------|
| `ffmpeg` *(default)* | The current production path. Starts one ffmpeg subprocess per sampling point. Always available. |
| `libav` | In-process software decoding through ffmpeg's libavcodec. **Requires `--features in-process-decode` at build time.** |
| `videotoolbox` | Apple VideoToolbox hardware decoding. **macOS only. Requires `--features in-process-decode`.** |
| `auto` | Tries VideoToolbox, then software libav, then FFmpeg. The first successful backend is used; failures cascade automatically. |

```sh
# Use the automatic fallback chain
vimg vcs -c3 -H160 -n9 --capture-backend auto video.mkv

# Force the current production backend (compatibility / rollback)
vimg vcs -c3 -H160 -n9 --capture-backend ffmpeg video.mkv
```

Named backends (`ffmpeg`, `libav`, `videotoolbox`) are **fail-fast**: if the
selected backend cannot complete the job the command fails immediately. Only
`auto` permits fallback.

### Capture Concurrency

The `-T` flag controls how many sampling points are captured concurrently:

```sh
# Auto (default: all sampling points run in parallel)
vimg vcs -c3 -H160 -n9 -T0 video.mkv

# Limit to 4 concurrent ffmpeg processes
vimg vcs -c3 -H160 -n9 -T4 video.mkv
```

`-T 0` (the default) means unbounded concurrency — all capture points run
simultaneously. An explicit `-T <N>` caps the number of concurrent decoders
without changing the output.

## Minimum supported rust compiler
Maintained with [latest stable rust](https://gist.github.com/alexheretic/d1e98d8433b602e57f5d0a9637927e0c).
