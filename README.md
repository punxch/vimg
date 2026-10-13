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
