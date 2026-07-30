# 11 — Prove the Auto default-promotion performance gate

**What to build:** Produce release-quality evidence that the aligned VideoToolbox path remains meaningfully faster and lower-CPU than software libav while satisfying visual, resource, and general performance contracts.

**Blocked by:** 10 — Tune bounded Capture concurrency.

**Status:** in-progress

- [x] At least 30 warm runs use rotated, interleaved ordering against aligned software libav and FFmpeg paths.  
  → 30 interleaved runs completed (odd runs: libav→ffmpeg; even: ffmpeg→libav). See `../promotion-gate-report.md`.
- [ ] VideoToolbox warm P95 is below 1.0 second on the representative Preview profile.  
  → **Not measurable.** VideoToolbox fails on Apple M4 with `av_hwframe_transfer_data` returning "Invalid argument". The ffmpeg CLI (`-hwaccel videotoolbox`) works with the same video, indicating a ffmpeg-next 8.1.0 binding issue. VT gate cannot be proven.
- [ ] VideoToolbox wall time improves at least 15% over aligned software libav.  
  → **Not measurable** (VT failure). Software libav improves 19.2% over FFmpeg, but the VT-vs-libav comparison is the required metric.
- [ ] VideoToolbox user CPU improves at least 70% over aligned software libav.  
  → **Not measurable** (VT failure). Software libav improves 31.6% over FFmpeg; the required 70% VT-vs-libav improvement is not shown.
- [ ] Active-job peak RSS remains no greater than 512MB.  
  → **❌ FAIL.** Software libav peak RSS = ~604 MiB (633 MB), exceeding the 512 MB ADR-0001 budget by ~18%. FFmpeg RSS = ~283 MiB (297 MB). The libav memory usage needs investigation.
- [x] The general warm P95 1.3-second contract remains satisfied.  
  → ✅ libav P95 = 1.030s, ffmpeg P95 = 1.280s. Both within ADR-0001's 1.3-second contract.
- [x] Source PTS, ordering, labels, animation structure, and per-frame SSIM contracts remain green under the selected concurrency.  
  → ✅ Byte-identical AVIF (SHA-256 match), 852×480 20fps 30-frame. Frame selection contract preserved.
- [ ] Cold starts are reported separately from the warm promotion result.  
  → Not yet measured. Cold-start performance requires separate measurement with cleared filesystem caches.
- [ ] Injected early and late fallback latency is reported separately and is not presented as a sub-second SLA.  
  → Fallback latency for VT→libav measured at ~0.2s overhead (VT failure detection + libav startup). Detailed profiling deferred.
- [x] If any gate fails, the report states that `auto` must remain opt-in rather than weakening the threshold.  
  → ✅ `auto` must remain opt-in. Three gates fail: VT P95, VT CPU improvement, and libav RSS. See `../promotion-gate-report.md` for the full analysis and recommendation.

## Comments

### 2026-07-30 — Measurement

Ran 30 interleaved warm runs of software libav vs FFmpeg on Apple M4. Key findings:

- **Software libav is viable**: 19% faster wall time, 32% lower CPU than FFmpeg. P95 = 1.030s (well within 1.3s contract). Output is byte-identical to FFmpeg.
- **VideoToolbox blocked on M4**: `av_hwframe_transfer_data` fails with "Invalid argument" on Apple M4. The ffmpeg CLI (`-hwaccel videotoolbox`) works correctly, so the issue is ffmpeg-next 8.1.0-specific. Needs investigation with newer ffmpeg-next or M4 workaround.
- **libav RSS exceeds budget**: ~604 MiB vs 512 MB limit. Memory profiling needed.
- **Fallback works correctly**: `auto` cascades VT→libav→FFmpeg with clean error propagation.

**Conclusion: `auto` must remain opt-in.** The default stays `ffmpeg` until VT hardware issue is resolved and libav RSS is brought within budget.

`../promotion-gate-report.md` has the full analysis.
