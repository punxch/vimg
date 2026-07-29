# 06 — Deliver whole-attempt fallback for direct VCS

**What to build:** Make direct VCS `auto` execution recover from a software libav Capture attempt failure by discarding the entire attempt and restarting with FFmpeg, without mixing frames or publishing partial output.

**Blocked by:** 05 — Deliver the explicit software libav Nonref backend.

**Status:** ready-for-agent

- [ ] `auto` can choose software libav and then FFmpeg in preference order on a feature-on non-macOS path.
- [ ] Unavailable adapters are skipped without starting a Capture attempt.
- [ ] Backend-owned setup, seek, decode, validation, and completion failures are classified as attempt failures and may fall back.
- [ ] Shared input, encoder, disk, publication, and cancellation failures are fatal and do not start another backend.
- [ ] Each attempt owns a fresh encoder and unique unpublished temporary output.
- [ ] Injected failure before the first frame, after the first grid, and on the final frame fully cleans workers, processes, encoder, channels, and temporary output.
- [ ] Every fallback starts the next backend at animation frame zero with the same Capture plan.
- [ ] Named `libav` and `ffmpeg` policies remain fail-fast.
- [ ] Final all-backends-failed errors contain each attempted backend, failure class, phase, and source reason.
- [ ] Normal fallback emits a concise diagnostic and profiling reports per-attempt timings.
