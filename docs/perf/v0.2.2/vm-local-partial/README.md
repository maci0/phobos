# First KVM attempt, incomplete study

This archive retains the first PC's 30 complete populated-history trials.
All 863,990 requests succeeded. The Ryzen 9 9950X host runs Linux
7.2.10-1-cachyos. The VM uses the same published v0.2.2 asset and Moonraker
pin as the second-PC study, with exclusive physical cores, four pinned FIFO
vCPUs, 4 GiB locked RAM and guest-loopback traffic.

The first empty-history capture filled the private 4 GiB filesystem before
completing. Offline journal replay confirmed exhausted capacity. Its unmatched
BEGIN event is retained in `host-events.json`; it has no result row. No complete
trial was removed. The later second-PC study uses a fresh 16 GiB disk and a
2 GiB free-space guard before each measured trial.

Guest steal counters and host scheduling delays are nonzero. These observations
do not satisfy literal zero steal or guaranteed physical performance. This
archive is excluded from the active comparison graphics, which use the complete
second-PC study. `status.json` and `cleanup.json` record the failure and restored
host state. Raw databases and response captures remain private.
