# 11 — Prove the Auto default-promotion performance gate

**What to build:** Produce release-quality evidence that the aligned VideoToolbox path remains meaningfully faster and lower-CPU than software libav while satisfying visual, resource, and general performance contracts.

**Blocked by:** 10 — Tune bounded Capture concurrency.

**Status:** ready-for-agent

- [ ] At least 30 warm runs use rotated, interleaved ordering against aligned software libav and FFmpeg paths.
- [ ] VideoToolbox warm P95 is below 1.0 second on the representative Preview profile.
- [ ] VideoToolbox wall time improves at least 15% over aligned software libav.
- [ ] VideoToolbox user CPU improves at least 70% over aligned software libav.
- [ ] Active-job peak RSS remains no greater than 512MB.
- [ ] The general warm P95 1.3-second contract remains satisfied.
- [ ] Source PTS, ordering, labels, animation structure, and per-frame SSIM contracts remain green under the selected concurrency.
- [ ] Cold starts are reported separately from the warm promotion result.
- [ ] Injected early and late fallback latency is reported separately and is not presented as a sub-second SLA.
- [ ] If any gate fails, the report states that `auto` must remain opt-in rather than weakening the threshold.
