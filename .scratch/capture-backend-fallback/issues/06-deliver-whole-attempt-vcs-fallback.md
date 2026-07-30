# 06 — Deliver whole-attempt fallback for direct VCS

**What to build:** Make direct VCS `auto` execution recover from a software libav Capture attempt failure by discarding the entire attempt and restarting with FFmpeg, without mixing frames or publishing partial output.

**Blocked by:** 05 — Deliver the explicit software libav Nonref backend.

**Status:** resolved

- [x] `auto` can choose software libav and then FFmpeg in preference order on a feature-on non-macOS path.
- [x] Unavailable adapters are skipped without starting a Capture attempt.
- [x] Backend-owned setup, seek, decode, validation, and completion failures are classified as attempt failures and may fall back.
- [x] Shared input, encoder, disk, publication, and cancellation failures are fatal and do not start another backend.
- [x] Each attempt owns a fresh encoder and unique unpublished temporary output.
- [x] Injected failure before the first frame, after the first grid, and on the final frame fully cleans attempt-owned resources before restart.
- [x] Every fallback starts the next backend at animation frame zero with the same Capture plan.
- [x] Named `libav` and `ffmpeg` policies remain fail-fast.
- [x] Final all-backends-failed errors contain each attempted backend, failure class, phase, and source reason.
- [x] Normal fallback emits a concise diagnostic and profiling reports per-attempt timings.

## Evidence

- Policy tests cover unavailable candidates, fail-fast named policies, fatal errors, all-failed aggregation, and injected early/middle/late attempt failures.
- Feature-on `auto` on the representative Preview input matches the FFmpeg authority: 270 selected source PTS and all 30 decoded AVIF frames at SSIM `1.0`.
- A non-Preview `auto` invocation skips software libav and completes through FFmpeg.
