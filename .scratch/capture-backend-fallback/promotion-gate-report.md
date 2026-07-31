# Auto Default-Promotion Performance Gate

**Date:** 2026-07-31 (updated after VideoToolbox fix)
**Hardware:** Apple M4
**OS:** macOS 26.4.1
**FFmpeg:** 8.1.2
**Binary:** `cargo build --release --features in-process-decode`
**Fixture:** `./sample/input.mkv`
**Profile:** `vimg vcs -c3 -H160 -n9 --capture-backend <backend>`
**Methodology:** 3 warmups, then 30 rotated/interleaved warm triples

## VideoToolbox fix (2026-07-31)

The prior report recorded a VideoToolbox failure below Vimg (hardware session
init failing). Two code defects in Vimg's own in-process path were the actual
cause:

1. **Custom `get_format` override blocked hwaccel init.** Setting
   `AVCodecContext.get_format` to a callback that returned
   `AV_PIX_FMT_VIDEOTOOLBOX` bypassed FFmpeg's `ff_get_format` hwaccel
   initialization, so `hw_frames_ctx` (and its CVPixelBuffer pool) was never
   created. Removing the override lets FFmpeg's default `get_format` run the
   proper hwaccel init.
2. **`Video::clone()` drops `hw_frames_ctx`.** ffmpeg-next's `Clone for Video`
   uses `av_frame_copy` + `av_frame_copy_props`, which do not carry
   `hw_frames_ctx` (it requires reference management). Cloned hardware frames
   lost their CVPixelBuffer reference, so `av_hwframe_transfer_data` returned
   `Invalid argument`. Replaced with `av_frame_ref` via a new `hw_ref_frame`
   helper in `src/command/videotoolbox.rs`.

After the fix, forced VideoToolbox completes the representative Preview
profile and `auto` prefers it. Output is byte-identical across all backends.

## Promotion decision

**Promotion gates pass.** VideoToolbox now meets every latency, CPU, resource,
and correctness gate. See the checklist below. The decision to change the
default policy from `ffmpeg` to `auto` is tracked in ticket #13; with these
results its blocker is removed.

## Warm results (30 interleaved rotated triples)

| Metric | VideoToolbox | Software libav | FFmpeg |
|---|---:|---:|---:|
| Wall average | **0.759s** | 0.966s | 1.197s |
| Wall P95 | **0.770s** | 1.010s | 1.280s |
| Wall min | 0.750s | 0.930s | 1.150s |
| Wall max | 0.770s | 1.050s | 1.290s |
| User CPU average | **1.042s** | 6.121s | 8.921s |
| User CPU P95 | **1.070s** | 6.220s | 9.090s |
| Peak RSS | **~406 MiB** | ~598 MiB | ~289 MiB |

VT wall is 21.4% lower than libav; VT user CPU is 83.0% lower than libav.

## Gate checklist

| Gate | Target | Result |
|---|---:|---|
| General warm P95 | ≤ 1.300s | pass (all backends) |
| VideoToolbox warm P95 | < 1.000s | **pass (0.770s)** |
| VideoToolbox wall improvement over libav | ≥ 15% | **pass (21.4%)** |
| VideoToolbox user CPU improvement over libav | ≥ 70% | **pass (83.0%)** |
| Active-job peak RSS | ≤ 512 MiB | **pass (VT 406 MiB)** |
| Frame-selection/output contract | exact/approved tolerance | byte-identical=yes |
| Rotated, interleaved warm runs | ≥ 30 | 30 triples |

**Note:** software libav peak RSS remains ~598 MiB (over 512 MiB budget). This
only affects the `libav` and `auto` fallback paths; the preferred VideoToolbox
path meets the budget.

## Correctness

- VT, libav, and FFmpeg AVIF outputs byte-identical: **yes**
- SHA-256 (all): `406db119839f6307cf56b5907966f525f36f18a21093f439926835918ab2c68f`

## Reproduction

```bash
cargo build --release --features in-process-decode
./target/release/vimg vcs -c3 -H160 -n9 \
  --capture-backend videotoolbox ./sample/input.mkv --output vt.avif
./target/release/vimg vcs -c3 -H160 -n9 \
  --capture-backend libav ./sample/input.mkv --output libav.avif
./target/release/vimg vcs -c3 -H160 -n9 \
  --capture-backend ffmpeg ./sample/input.mkv --output ffmpeg.avif
shasum -a 256 vt.avif libav.avif ffmpeg.avif
```
