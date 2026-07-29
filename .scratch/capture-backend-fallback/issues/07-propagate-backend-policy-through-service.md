# 07 — Propagate Capture backend policy through the local service

**What to build:** Let the local preview service fix one Capture backend policy at startup and use the same whole-attempt behavior as direct VCS while remaining transparent to existing preview clients and cache consumers.

**Blocked by:** 06 — Deliver whole-attempt fallback for direct VCS.

**Status:** ready-for-agent

- [ ] Service startup accepts the same backend-policy values as direct VCS.
- [ ] Every Capture job in one service process uses the startup policy.
- [ ] The existing TCP request and lifecycle response contract remains unchanged.
- [ ] A Coalesced capture job shares one final result even when more than one Capture attempt occurs.
- [ ] Only one complete successful attempt becomes a Published preview cache.
- [ ] Backend identity and attempt count do not change cache identity or manifest validation.
- [ ] All waiting requesters receive the same completion or terminal failure.
- [ ] Fallback cleanup completes before another backend begins and before the next queued Capture job executes.
- [ ] Integration coverage proves explicit, automatic, and fatal-error service behavior through the service request seam.
