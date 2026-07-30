# 11 — Prove the Auto default-promotion performance gate

**What to build:** Produce release-quality evidence that the aligned VideoToolbox path remains meaningfully faster and lower-CPU than software libav while satisfying visual, resource, and general performance contracts.

**Blocked by:** 10 — Tune bounded Capture concurrency.

**Status:** done — promotion rejected

- [x] At least 30 warm runs use rotated, interleaved ordering against aligned software libav and FFmpeg paths.  
  → 30 rotated, interleaved pairs completed. Raw observations are in `../promotion-gate-results.tsv`; see `../promotion-gate-report.md`.
- [ ] VideoToolbox warm P95 is below 1.0 second on the representative Preview profile.  
  → **Not measurable.** VideoToolbox fails before returning a hardware frame. FFmpeg 8.1.2's CLI and installed official `hw_decode.c` example reproduce the same VideoToolbox session-initialization failure, so this is not isolated to Vimg's transfer path or the Rust bindings.
- [ ] VideoToolbox wall time improves at least 15% over aligned software libav.  
  → **Not measurable** (VT failure). Software libav's result is not substituted for the required VT-vs-libav comparison.
- [ ] VideoToolbox user CPU improves at least 70% over aligned software libav.  
  → **Not measurable** (VT failure). The required VT-vs-libav improvement is not shown.
- [ ] Active-job peak RSS remains no greater than 512MB.  
  → **FAIL.** See the generated report for current peak RSS evidence.
- [ ] The general warm P95 1.3-second contract remains satisfied.
  → **FAIL.** The current 30-pair run places FFmpeg just outside the strict threshold; see the generated report.
- [x] Source PTS, ordering, labels, animation structure, and per-frame SSIM contracts remain green under the selected concurrency.  
  → The latest software-libav and FFmpeg outputs are byte-identical; hashes and structure evidence are in the generated report.
- [x] Cold starts are reported separately from the warm promotion result.
  → First-process observations are reported separately and explicitly are not presented as filesystem-cache-cold measurements.
- [x] Injected early and late fallback latency is reported separately and is not presented as a sub-second SLA.
  → Real early VT→libav fallback is measured separately. Late injected fallback remains a correctness/stress scenario and is explicitly excluded from the warm distribution and sub-second SLA until a lifecycle fault-injection benchmark exists.
- [x] If any gate fails, the report states that `auto` must remain opt-in rather than weakening the threshold.  
  → `auto` remains opt-in and `ffmpeg` remains the default. No failed threshold is weakened.

## Comments

### 2026-07-30 — Completion

Repaired `src/bin/bench_promotion_gate.sh` so it runs on macOS Bash, fails on
required-backend errors, records raw TSV evidence, supports report regeneration,
computes complete statistics, checks output identity, and keeps first-process
and fallback observations separate from the warm distribution.

The forced VideoToolbox failure was reproduced independently with FFmpeg's CLI
and official C hardware-decoding example. Both fail during VideoToolbox session
initialization before returning a hardware frame. Vimg's strict hardware-format
check is therefore behaving correctly by rejecting FFmpeg's software fallback.

The completed gate rejects default promotion. `../promotion-gate-report.md`
contains the generated decision and statistics; `../promotion-gate-results.tsv`
contains the raw observations.
