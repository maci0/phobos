# Earlier and rejected experiments

These records preserve intermediate and negative results. Active performance
tables and plots use the final selected 64 KiB reader, standard startup allocator
and longer minimum-count VM trials. Each directory describes its variant.
Do not pool studies or compute speedups across different durations or collectors.

The SIMD encoder CPU microbenchmarks use fixed inputs, process CPU time and three
repetitions. They are diagnostics, not isolated server request benchmarks. The
ARM microbenchmark's ru_maxrss is a rolling child-process maximum, not a valid
per-variant RSS comparison. Parser pre-sizing/inlining alternatives did not earn
a consistent gain and were not added to the source. `firstTrue` was slower than
the selected mask/ctz implementation on ARM. Source and binary hashes remain in
the numeric captures where collected.

The invalid FIFO/idle-poll study and mixed-clock printer assertion are harness
failures, not daemon-crash findings. Partial rows are excluded from final verdicts.
Earlier API identity/default/environment differences remain documented separately.
Private seeds, job bodies, logs and binary load captures are not published here.
Printer trial exports retain every trial and its CPU/RSS/latency/throughput
statistics and affinity. Per-request timestamps and full sample streams remain
in ignored scratch captures; source JSON hashes identify those originals.
