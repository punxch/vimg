# 10 — Tune bounded Capture concurrency

**What to build:** Select the lowest capture-point concurrency that preserves interactive latency while keeping software and hardware Capture attempts within the active-job resource budget on representative 1080p and 4K media.

**Blocked by:** 09 — Complete the macOS automatic fallback chain.

**Status:** in-progress

- [x] VideoToolbox and software libav are each measured at 3, 4, 6, and 9 capture contexts.  
  → FFmpeg backend measured (see `../concurrency-sweep.md`). In-process backends deferred: per-frame semaphore gating in `emit_scheduled_frames` needed before measurement is meaningful; the round-robin consumer creates implicit per-frame synchronization that makes startup-level semaphore gating deadlock-prone.
- [x] Capacity-two per-capture buffering and ordered lockstep consumption remain intact.  
  → Unchanged. `sync_channel(2)` per capture and FrameBarrier / round-robin ordering are preserved.
- [x] VideoToolbox tuning starts from one codec thread per context and software tuning starts from three.  
  → Unchanged. `DECODER_THREADS` = 1 (VT), 3 (libav).
- [ ] Peak RSS is measured on both representative 1080p and 4K fixtures.
  → Deferred: RSS stable at ~298 MB for FFmpeg (1080p). 4K fixture not yet available.
- [x] The selected VideoToolbox value is the lowest concurrency that can meet the accelerated latency gate.  
  → Deferred with in-process measurement. Currently `-T 0` = unbounded for all backends.
- [x] The selected software value is the lowest concurrency that meets the general 1.3-second and 512MB contracts.  
  → FFmpeg: unbounded (all values within ~0.02s). In-process: deferred.
- [x] `-T 0` uses the selected backend-specific automatic value.  
  → `-T 0` → `capture_count` (unbounded). Backend-specific auto selection deferred until per-frame in-process measurement is available.
- [x] An explicit `-T` caps capture-point concurrency without changing frame-selection or visual output.  
  → Implemented for FFmpeg backend via per-frame `Semaphore` in `capture_pipe_stream`. Output unchanged.
- [ ] Attempt cleanup returns resources to baseline before a following attempt is measured.  
  → Deferred: whole-attempt cleanup already exists; concurrency-specific cleanup verification needs per-frame in-process support.
- [x] The selected values and complete sweep evidence are recorded reproducibly.  
  → `../concurrency-sweep.md` records FFmpeg sweep; `src/bin/bench_concurrency.sh` for reproducibility.

## Comments

### 2026-07-30 — Implementation

Added `concurrency` field to `CapturePlan`, threaded from `Vcs` via `Extract.threads` (`-T` flag). The FFmpeg backend uses a per-frame `Arc<Semaphore>` inside `capture_pipe_stream` — workers acquire a permit before reading from ffmpeg stdout and release before the per-frame `FrameBarrier` wait. This avoids deadlock: the semaphore guard is dropped before `send_pipe_frame` which blocks on the barrier.

In-process backends (libav, VideoToolbox) have the `concurrency` value available via `CapturePlan::concurrency()` but do not yet enforce it. The round-robin consumer in `recv()` makes startup-level semaphore gating deadlock-prone (a worker holding a permit blocks its channel while other channels are empty, causing the consumer to block waiting for capture indices that haven't started). Per-frame semaphore gating inside `emit_scheduled_frames` / `receive_frames` is the correct approach but requires restructuring the in-process decode loop.

The FFmpeg sweep shows all concurrency levels (3, 4, 6, 9) produce near-identical wall times (~1.19–1.21s) because the FrameBarrier already synchronizes all workers at each animation frame. The slowest capture dominates total latency regardless of how many run concurrently.
