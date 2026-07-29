# 01 — Establish the production FFmpeg authority

**What to build:** Make the current production FFmpeg Capture backend produce a repeatable, test-only authority record for the representative Preview profile without changing its normal AVIF output. The record must make source-frame selection and visual comparison observable enough for later backends to prove compatibility.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

- [ ] One repeatable validation run records all 270 selected source PTS with their capture and animation indices.
- [ ] The same run records the final animation dimensions, framerate, duration, frame count, and visual reference frames.
- [ ] Normal production output remains unchanged when authority instrumentation is disabled.
- [ ] The visual checker evaluates every frame rather than only an animation-wide average.
- [ ] The checker accepts identical output and rejects the known SSIM 0.9685 frame-selection mismatch.
- [ ] The checker rejects the previously rejected bilinear result at SSIM 0.9951 against the required 0.999 threshold.
- [ ] Failure messages identify whether PTS extraction, structural inspection, decoding, or visual comparison failed.
