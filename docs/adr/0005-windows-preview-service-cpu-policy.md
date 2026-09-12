# ADR-0005: Prefer performance cores for the native Windows preview service

Date: 2026-09-12
Status: Accepted

## Context

On the development i9-12900K, resident native preview jobs can change from about
1.1 seconds to 1.9 seconds after the process has been alive for several seconds.
Waiting ten seconds before the first render also reproduces the slowdown.
Restricting a diagnostic child to the performance cores removes it in an ABBA
comparison using the same executable. This supports a scheduling explanation;
it does not establish which Windows scheduling mechanism causes the transition.

The earlier short CLI affinity experiment did not exercise this aged-service
condition. CLI startup and resident service latency need separate measurements.

## Decision

`serve --cpu-policy auto` uses Windows CPU-set EfficiencyClass information to
select the fastest available class before creating service workers. The mask is
computed at runtime. It applies only to native-capable Windows builds using the
auto or libav capture policy. `vcs` and other commands do not change affinity.

Preserve inherited affinity and explicit process-default CPU Sets. Skip the
policy on homogeneous CPUs, multiple processor groups or unsupported topology.
Exclude CPU Sets exclusively allocated to other processes. Query or application
failure is nonfatal and retains OS scheduling. Do not change system power plans,
process priority, global core settings, frame selection or encoding parameters.

`serve --cpu-policy all` preserves OS scheduling, including any parent-imposed
restrictions. It is available for throughput comparisons and other hardware.

## Consequences and validation

Core restrictions trade scheduling freedom for predictable preview latency.
The single-job P95 goal and multi-job throughput must both be measured; passing
the latency goal does not imply the separate memory budget is satisfied.
The service still admits at most ten jobs. The real-render ignored benchmark
shares the production policy setup and checks repeated output and cache reuse.
A separate ignored benchmark compares four and ten simultaneous native renders
and checks that each output is byte-identical within its batch. Detailed timings,
binary identities and remaining limits are recorded in report.md.

The topology parser is tested for heterogeneous and homogeneous CPUs, inherited
allowed masks, exclusive allocation, multiple groups, unknown record types and
malformed or extended records. Non-ignored unit tests do not change process affinity.

API references: [CPU-set record semantics](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-system_cpu_set_information),
[process-default CPU Sets](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getprocessdefaultcpusets).
