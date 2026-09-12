# ADR-0007: Allocate the native preview encoder when its first grid is ready

Date: 2026-09-12
Status: Accepted

## Context

The one-worker service removes the resource multiplication across Capture jobs,
but repeated native previews still peak at about 537 MiB on the representative
input. Phase sampling shows the encoder is initialized around 0.05 seconds,
while the first complete grid is ready around 0.9 seconds. Its pools overlap
the full-resolution buffers of the parallel decoders during seek preroll.

## Decision

For a libav Capture attempt using the fixed Preview profile and the in-process
AVIF encoder, keep the GridEncoder pending until write_grid receives its first
complete grid. At that point, use the existing encoder startup path, including
its FFmpeg subprocess fallback, and submit that same grid exactly once.

Keep other Capture backends, explicit subprocess encoding and non-preview
profiles on their existing eager startup path. The selected backend for each
attempt determines deferral, including automatic policy fallback. Preserve
decoder concurrency, frame selection, encoder settings and output publication.

A capture failure before the first grid no longer allocates encoder resources.
An encoder startup failure still follows the existing encoder fallback policy;
fatal errors still stop the Capture job. Finishing a pending encoder without
any grid is an error. Dropping it requires no worker or output cleanup.

## Consequences and validation

This reduces simultaneous decoder and encoder allocations without serializing
the whole decode/encode pipeline. Encoder initialization moves onto the first
grid's write path, so timing must be measured alongside the memory reduction.
It is not a heap trim, a working-set purge, or a change in output quality.

A lifecycle test checks that output creation waits for the first grid, then
completes a real encode. The existing repeated-service benchmark supports a
longer optional repetition count for memory stability checks. A test-only eager
switch permits controlled comparisons in one binary. CLI, resident, long-run
and golden-corpus results and remaining budget limits are recorded in report.md.
