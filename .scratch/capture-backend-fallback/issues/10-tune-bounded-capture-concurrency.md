# 10 — Tune bounded Capture concurrency

**What to build:** Select the lowest capture-point concurrency that preserves interactive latency while keeping software and hardware Capture attempts within the active-job resource budget on representative 1080p and 4K media.

**Blocked by:** 09 — Complete the macOS automatic fallback chain.

**Status:** ready-for-agent

- [ ] VideoToolbox and software libav are each measured at 3, 4, 6, and 9 capture contexts.
- [ ] Capacity-two per-capture buffering and ordered lockstep consumption remain intact.
- [ ] VideoToolbox tuning starts from one codec thread per context and software tuning starts from three.
- [ ] Peak RSS is measured on both representative 1080p and 4K fixtures.
- [ ] The selected VideoToolbox value is the lowest concurrency that can meet the accelerated latency gate.
- [ ] The selected software value is the lowest concurrency that meets the general 1.3-second and 512MB contracts.
- [ ] `-T 0` uses the selected backend-specific automatic value.
- [ ] An explicit `-T` caps capture-point concurrency without changing frame-selection or visual output.
- [ ] Attempt cleanup returns resources to baseline before a following attempt is measured.
- [ ] The selected values and complete sweep evidence are recorded reproducibly.
