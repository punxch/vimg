# 04 — Prefactor FFmpeg behind the Capture backend module

**What to build:** Route the existing production Preview profile through one deep Capture backend module with FFmpeg as its first adapter, making future backends easy to add while preserving current user-visible behavior.

**Blocked by:** 02 — Reproduce the FFmpeg Frame selection contract.

**Status:** ready-for-agent

- [ ] VCS orchestration uses one Capture module interface for normalized planning, bounded ordered frames, completion, and diagnostics.
- [ ] FFmpeg satisfies the internal Capture backend seam without exposing child-process or channel details to callers.
- [ ] A Capture plan computes shared media properties, capture windows, frame schedule, output dimensions, and labels once.
- [ ] The existing default Preview profile produces the same PTS, structure, labels, and visual output as the authority.
- [ ] General VCS profiles, JPG/WebP output, and custom filters retain their current compatibility behavior.
- [ ] Existing FFmpeg errors remain actionable and no new in-process build dependency is introduced.
- [ ] Default command performance remains within normal measurement noise of the pre-refactor path.
- [ ] Module-level tests assert observable frames and results rather than private worker or channel state.
