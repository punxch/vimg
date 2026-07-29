# 13 — Promote Auto to the shared default

**What to build:** After all correctness, hardware, resource, CI, and performance evidence is complete, make automatic Capture backend selection the default for direct VCS and the local service while retaining explicit rollback controls.

**Blocked by:** 11 — Prove the Auto default-promotion performance gate; 12 — Add feature-on CI and the opt-in rollout path.

**Status:** ready-for-agent

- [ ] Promotion occurs only when every dependency records passing acceptance evidence.
- [ ] Direct VCS and service use the same default Capture backend policy.
- [ ] A feature-on macOS build defaults to VideoToolbox, software libav, then FFmpeg.
- [ ] A feature-on supported non-macOS build defaults to software libav, then FFmpeg.
- [ ] A feature-off build's automatic candidate list contains only FFmpeg and preserves existing behavior.
- [ ] Explicit `videotoolbox`, `libav`, and `ffmpeg` policies remain fail-fast and unchanged.
- [ ] Cache identity, client protocol, Preview profile, and AVIF encoder remain unchanged.
- [ ] Release notes state the promotion gates, platform behavior, dependency model, and rollback command.
- [ ] A final smoke run verifies successful automatic selection, complete fallback, and forced FFmpeg compatibility.
