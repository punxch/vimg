# 09 — Complete the macOS automatic fallback chain

**What to build:** Make direct VCS and the local service execute the complete macOS preference order VideoToolbox Nonref, software libav Nonref, then FFmpeg with correct availability caching, cleanup, diagnostics, and cache transparency.

**Blocked by:** 07 — Propagate Capture backend policy through the local service; 08 — Deliver the explicit VideoToolbox Nonref backend.

**Status:** claimed

- [x] macOS `auto` assembles VideoToolbox, software libav, and FFmpeg in the accepted order.
- [x] A deterministic process-level VideoToolbox device failure is cached and skipped by later Capture jobs.
- [x] Codec and media capability failures affect only the current media.
- [x] A runtime VideoToolbox attempt failure does not permanently disable hardware for later media.
- [ ] Direct VCS and service tests cover VideoToolbox to libav, VideoToolbox through libav to FFmpeg, and direct capability skip to FFmpeg.
- [x] Forced policies never participate in automatic fallback.
- [x] No decoder context, child process, channel, frame buffer, encoder, or temporary output overlaps the next attempt.
- [x] Normal diagnostics identify the selected backend and fallback reason without changing client responses.
- [ ] Profiling includes availability, first frame/grid, decoded/preroll frames, hardware transfers, cleanup, encoder, and total timings per attempt.
- [x] Any successful backend publishes to the same cache identity.
