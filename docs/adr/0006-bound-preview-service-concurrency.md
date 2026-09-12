# ADR-0006: Default to one executing preview with a configurable worker limit

Date: 2026-09-12
Status: Accepted

## Context

ADR-0001 specifies one executing Capture job and up to nine queued jobs. The
service nevertheless started ten workers. Each native Capture job already
decodes multiple sampling regions concurrently and runs a parallel encoder.
Simultaneous jobs multiply that CPU and memory demand.

An exploratory alternating-order comparison on the development i9-12900K used the same
binary, native backend, automatic CPU policy and ten-job batch. One worker
delivered the first output in about 1.27 seconds with a 542 MiB peak working
set; ten workers needed about 13.83 seconds and 3,882 MiB. Four workers had
the best batch throughput in this experiment, at the cost of later first
output and substantially higher memory use. See report.md for raw timings
and background-load limitations.

## Decision

`serve` defaults to one worker. `serve --jobs N` (or `-j N`) accepts 1 through
10 for users who choose a different latency, memory and throughput tradeoff.
The ten-job admission limit counts both executing and queued jobs regardless
of worker count. At capacity, preserve executing jobs and replace the oldest
unstarted job; if all ten are executing, respond `busy`. The newest queued
job runs next, and duplicate requests still share their existing job.

Keep Capture job internals, CPU policy, Preview profile, publication and
notification behavior unchanged. The worker limit also applies to explicit
FFmpeg and fallback Capture attempts. Standalone `vcs` behavior is unchanged.

## Consequences and validation

The default prioritizes an interactive preview and avoids multiplying active
job resources by ten. It does not guarantee maximum batch throughput on every
machine or input, nor does it solve the remaining single-job memory excess
over the ADR-0001 target. With one worker, queued requests also wait for the
current Capture job to finish; the measured first output of a prequeued batch
does not include DDS transport or an already executing job's residual time.

The ignored queued-service benchmark parses the same worker setting as the
CLI, drains actual Scheduler jobs through complete_job, verifies byte-identical
outputs against an optional golden AVIF, and checks cache reuse. Unit tests
cover defaults and limits, eviction while one job is active, coalescing,
failure cleanup and saturation with ten active jobs.
