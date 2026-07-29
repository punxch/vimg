# 01 — Establish the production FFmpeg authority

**What to build:** Make the current production FFmpeg Capture backend produce a repeatable, test-only authority record for the representative Preview profile without changing its normal AVIF output. The record must make source-frame selection and visual comparison observable enough for later backends to prove compatibility.

**Blocked by:** None — can start immediately.

**Status:** resolved

- [x] One repeatable validation run records all 270 selected source PTS with their capture and animation indices.
- [x] The same run records the final animation dimensions, framerate, duration, frame count, and visual reference frames.
- [x] Normal production output remains unchanged when authority instrumentation is disabled.
- [x] The visual checker evaluates every frame rather than only an animation-wide average.
- [x] The checker accepts identical output and rejects the known SSIM 0.9685 frame-selection mismatch.
- [x] The checker rejects the previously rejected bilinear result at SSIM 0.9951 against the required 0.999 threshold.
- [x] Failure messages identify whether PTS extraction, structural inspection, decoding, or visual comparison failed.

## Answer

Implemented `vimg authority record` and `vimg authority verify`.

The record command is restricted to the fixed Preview profile. It uses FFmpeg
pre-encoder statistics to preserve each selected frame's integer input PTS and
original time base, streams the normal RGB frames through the existing bounded
pipeline, and writes both lossless pre-encoder grids and decoded AVIF references.
The manifest also records the 852×480 dimensions, 20/1 frame rate, 1.5-second
duration, and 30-frame count.

The verify command checks structure first and then evaluates all 30 decoded
frames independently at the required SSIM 0.999 threshold. Tests cover identical
frames and the known 0.9685 and 0.9951 rejection cases. Errors consistently name
the PTS extraction, structural inspection, decoding, or visual comparison phase.

Manifest and output paths are locked across processes for the complete authority
run. Visual references use immutable content-addressed generations; the AVIF and
manifest publish with rollback guards, and a successful publish removes stale
owned generations.

On the representative input, two repeated authority runs produced identical
manifests and AVIF bytes. The instrumented AVIF was byte-identical to the existing
production output, while five normal warm runs remained at 1.19–1.30 seconds.
