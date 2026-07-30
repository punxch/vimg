# 04 — Prefactor FFmpeg behind the Capture backend module

**What to build:** Route the existing production Preview profile through one deep Capture backend module with FFmpeg as its first adapter, making future backends easy to add while preserving current user-visible behavior.

**Blocked by:** 02 — Reproduce the FFmpeg Frame selection contract.

**Status:** claimed

- [x] VCS orchestration uses one Capture module interface for normalized planning, bounded ordered frames, completion, and diagnostics.
- [x] FFmpeg satisfies the internal Capture backend seam without exposing child-process or channel details to callers.
- [ ] A Capture plan computes shared media properties, capture windows, frame schedule, output dimensions, and labels once.
- [x] The existing default Preview profile produces the same PTS, structure, labels, and visual output as the authority.
- [x] General VCS profiles, JPG/WebP output, and custom filters retain their current compatibility behavior.
- [x] Existing FFmpeg errors remain actionable and no new in-process build dependency is introduced.
- [x] Default command performance remains within normal measurement noise of the pre-refactor path.
- [x] Module-level tests assert observable frames and results rather than private worker or channel state.

## Answer

Added a Capture module that owns normalized media, capture windows, canonical frame-rate schedules, output dimensions, labels, bounded ordered frame streaming, completion, and backend diagnostics. VCS now uses only this module interface. The first FFmpeg adapter is behind a backend-neutral attempt seam; VCS no longer sees its child processes, workers, or channels.

Remaining: the plan does not yet persist a source time base and fully materialized `FrameSchedule` instances, so that checklist item remains open for the next implementation slice.

The representative module stream test consumes all 270 observable frames and confirms complete authority records. The release authority output remains byte-identical (`406db119839f6307cf56b5907966f525f36f18a21093f439926835918ab2c68f`), with 270 PTS from `183100` to `3113736`. Paired same-machine measurements were 1.64s for the refactor versus 1.56–1.72s for the Ticket 02 baseline. JPG and custom-filter compatibility runs pass; WebP retains the baseline's existing Broken pipe failure. Full tests and Clippy pass.
