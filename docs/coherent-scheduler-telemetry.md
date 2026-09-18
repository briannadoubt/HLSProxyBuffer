# Coherent scheduler/cache telemetry publication

`HLSStreamingTelemetry.updateSchedulerTelemetry` accepts optional `cacheMetrics`.
When supplied, changed cache counters and scheduler gauges are published together
in one snapshot. Cache-only changes still publish even when scheduler gauges are
unchanged. Omitting the argument preserves the existing scheduler-only behavior;
`updateCacheMetrics` remains available. Unchanged values remain deduplicated.

The proxy's scheduler callback reads cache metrics once and supplies them with
the scheduler update, avoiding a second telemetry-actor call and intermediate
snapshot. This is one coherent publication of the observed values, not a claim
that the two source actors were sampled simultaneously. No counters, fetch/error
records, retry outcomes or terminal reports are disabled or sampled away.

This additive public API belongs in the next minor release. The revision-pinned
trial will measure performance separately; fewer publications alone do not prove
CPU, energy, latency or fleet-scale gains.
