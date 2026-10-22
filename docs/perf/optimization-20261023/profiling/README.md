# Ten profiling rounds

These are diagnostic optimized builds with symbols and frame pointers, not
release benchmark timings. CPU profiles sample owned processes at 997 Hz for
20 seconds. Fixed-arrival drivers run longer than the trace. Uninstrumented
paired trials pin server and generator threads to separate cores but do not
reserve an exclusive CPU partition or fix frequency. Three alternating pairs
retain every result. Lower CPU, latency and RSS are better. Requested allocation
bytes and mmap lengths are not RSS. Trial maxima are sampled, not exact peaks.

`rounds.json` records all ten audits and tests. CPU sample summaries retain
the 30 largest leaf and inclusive counts. Inclusive counts overlap. Numbered
paired files preserve the measured process and generator results. Intermediate
variants remain visible: direct SMP startup, the first SQL parser extension
and generic Unicode substring search regressed and were rejected. The accepted
round 5 variant is `scalar`; the accepted round 7 variant is `exact`.

Round 8's default-limit 200/s sessions correctly encounter HTTP 503; these are
overload diagnostics, not successful timing trials. Its accepted allocation
stress uses a private 100-connection limit. Session JSON preserves offered
arrival times and start delay. Round 9 validates large WebSocket replies;
outbound TLS is tested separately, not profiled. Round 10 ran alongside a
compiler and supports CPU attribution only. Optional unloaded components were
not individually profiled. No additional code change was justified in rounds
8 through 10.

All fixtures use private databases and fake Klippy sockets. Fixture console
commands never reach hardware. Final uninstrumented release comparisons in
the parent report use separate isolated VMs and the physical Forge-X printer.
Private fixture databases, process logs and full raw traces remain in ignored
scratch storage.
