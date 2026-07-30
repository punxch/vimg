# 07 — Propagate Capture backend policy through the local service

**What to build:** Let the local preview service fix one Capture backend policy at startup and use the same whole-attempt behavior as direct VCS while remaining transparent to existing preview clients and cache consumers.

**Blocked by:** 06 — Deliver whole-attempt fallback for direct VCS.

**Status:** resolved

- [x] Service startup accepts the same backend-policy values as direct VCS.
- [x] Every Capture job in one service process uses the startup policy.
- [x] The existing TCP request and lifecycle response contract remains unchanged.
- [x] A Coalesced capture job shares one final result even when more than one Capture attempt occurs.
- [x] Only one complete successful attempt becomes a Published preview cache.
- [x] Backend identity and attempt count do not change cache identity or manifest validation.
- [x] All waiting requesters receive the same completion or terminal failure.
- [x] Fallback cleanup completes before another backend begins and before the next queued Capture job executes.
- [x] Integration coverage proves explicit, automatic, and fatal-error service behavior through the service request seam.

## Evidence

- Service startup parses the same `auto`, `libav`, and `ffmpeg` policy values as direct VCS, then passes one immutable policy to its single worker.
- Request parsing deliberately does not include backend identity; repeated requests with an ignored backend field still coalesce by cache path and return `queued` then `shared`.
- The service-owned VCS construction carries the startup policy, while a fatal preflight error leaves no output path behind; service execution tests cover explicit and `auto` policies, fatal non-publication, and queue release.
- Coalesced requests aggregate every Yazi subscriber by cache and publish one ready or failed terminal event to the full group without changing the TCP `queued/shared` response.
