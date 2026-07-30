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
