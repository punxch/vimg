# Fall back by whole Capture attempt

Automatic Capture backend selection falls back in the order VideoToolbox Nonref, software libav Nonref, then the existing FFmpeg subprocess. If a backend is unavailable or its Capture attempt fails, Vimg must stop and join every worker, terminate the attempt's encoder, remove its unpublished temporary output, and restart from animation frame zero with the next backend; frames from different backends are never mixed. Shared input, encoding, publication, and cancellation failures terminate the Capture job instead of triggering fallback.

This deliberately accepts additional latency after a late backend failure in exchange for deterministic frame ordering, bounded resource ownership, and a cache produced by exactly one successful Capture attempt. The selected backend is diagnostic information and does not become part of cache identity.
