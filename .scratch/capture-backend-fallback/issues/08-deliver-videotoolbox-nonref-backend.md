# 08 — Deliver the explicit VideoToolbox Nonref backend

**What to build:** Allow a macOS feature-on build to complete the fixed Preview profile through VideoToolbox with 0.5-second Nonref preroll and selected-frame transfer, while reporting unsupported hardware cases honestly.

**Blocked by:** 03 — Expand the hardware-boundary media corpus; 05 — Deliver the explicit software libav Nonref backend.

**Status:** claimed

- [x] VideoToolbox code is compiled only on macOS and feature-off builds remain unchanged.
- [x] An explicit `videotoolbox` policy runs exactly one fail-fast hardware Capture attempt.
- [ ] The backend is eligible only for the fixed Preview profile and supported H.264/HEVC hardware configurations.
- [x] One process-level VideoToolbox device is shared safely across the capture contexts.
- [x] Selected frames originate as hardware frames, and only selected frames are transferred to system memory.
- [x] Software decoder fallback inside the VideoToolbox adapter remains zero.
- [ ] All selected PTS exactly match the Frame selection contract on supported expanded fixtures.
- [ ] Pre-encoder grids and decoded AVIF frames meet the per-frame SSIM 0.999 contract.
- [ ] Unsupported bit depth, chroma, codec, profile, or hardware configuration returns a clear unavailable result.
- [ ] Device creation, seek, decode, transfer, and completion errors identify the failing phase.
