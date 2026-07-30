# Capture-Point Concurrency Sweep

**Date:** 2026-07-30
**Binary:** release (ffmpeg-only)
**Fixture:** `./sample/input.mkv` (3.0 GB, 1080p H.264)
**Command:** `vimg vcs -c3 -H160 -n9 -T<N> ./sample/input.mkv --output /tmp/out.avif`
**Warmup:** 1 run
**Measurement runs:** 5 per concurrency level

## FFmpeg Backend

| T | Run 1 | Run 2 | Run 3 | Run 4 | Run 5 | **Average** |
|---:|---:|---:|---:|---:|---:|---:|
| 3 | 1.20s | 1.28s | 1.26s | 1.17s | 1.15s | **1.212s** |
| 4 | 1.19s | 1.15s | 1.17s | 1.23s | 1.23s | **1.194s** |
| 6 | 1.17s | 1.19s | 1.25s | 1.17s | 1.16s | **1.188s** |
| 9 | 1.25s | 1.15s | 1.19s | 1.17s | 1.28s | **1.208s** |

**Finding:** All concurrency levels produce nearly identical wall times (~1.19–1.21s). The per-frame FrameBarrier already serializes worker progress — all nine workers synchronize at each animation frame, so the slowest capture dominates total latency regardless of how many run concurrently. Limiting concurrency does not reduce wall time for the FFmpeg backend.

**Selected FFmpeg auto value:** `0` (unbounded → `capture_count` = 9). This preserves current behavior with no regression.

## In-Process Backends

Not yet measured. The in-process backends (libav, VideoToolbox) use a round-robin consumer that implicitly synchronizes workers at each frame, similar to the FrameBarrier. Per-frame semaphore gating inside `emit_scheduled_frames` would be needed to support concurrency limiting for these backends. The `CapturePlan::concurrency` infrastructure is in place; actual enforcement in `libav::start` and `videotoolbox::start` requires per-frame semaphore insertion in `receive_frames` / `emit_scheduled_frames`.

## Implementation Decisions

- **`-T 0` (auto):** Uses unbounded concurrency (`capture_count`) for all backends. This is the correct default since the FFmpeg backend shows no benefit from limiting, and in-process backends don't yet support limiting.
- **Explicit `-T <N>`:** Caps capture-point concurrency. For the FFmpeg backend, this limits how many ffmpeg subprocesses are actively decoding at each frame via per-frame semaphore gating.
- **Output correctness:** Concurrency value does not affect frame selection, grid dimensions, labels, or visual output.
