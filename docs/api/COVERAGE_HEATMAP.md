## API Coverage Heatmap

| Component | Endpoints | Methods | Notifications | Surface | Depth | Combined |
|-----------|-----------|---------|---------------|---------|-------|----------|
| 🟡 sensor | 3/3 | 3/3 | 1/1 | 100% | 55% | 55% |
| 🟠 mqtt | 2/2 | 3/3 | 0/0 | 100% | 35% | 35% |
| 🟠 power | 5/5 | 6/6 | 1/1 | 100% | 35% | 35% |
| 🟠 spoolman | 3/3 | 4/4 | 2/2 | 100% | 35% | 35% |
| 🟠 td1 | 2/2 | 2/2 | 0/0 | 100% | 35% | 35% |
| 🟠 update_manager | 10/10 | 10/10 | 2/2 | 100% | 35% | 35% |
| 🟠 wled | 6/6 | 7/7 | 0/0 | 100% | 35% | 35% |
| 🟢 button | 0/0 | 0/0 | 1/1 | 100% | 80% | 80% |
| 🟠 machine | 12/12 | 12/12 | 2/2 | 100% | 40% | 40% |
| 🟡 klippy_apis | 6/6 | 6/6 | 0/0 | 100% | 75% | 75% |
| 🟡 job_queue | 5/5 | 8/8 | 1/1 | 100% | 80% | 80% |
| 🟢 announcements | 5/5 | 6/6 | 3/3 | 100% | 90% | 90% |
| 🟡 webcam | 3/3 | 3/3 | 1/1 | 100% | 80% | 80% |
| 🟢 file_manager | 10/10 | 10/10 | 1/1 | 100% | 90% | 90% |
| 🟢 history | 4/4 | 5/5 | 1/1 | 100% | 85% | 85% |
| 🟢 analysis | 4/4 | 4/4 | 0/0 | 100% | 95% | 95% |
| 🟢 authorization | 9/9 | 10/10 | 3/3 | 100% | 95% | 95% |
| 🟢 common | 0/0 | 0/0 | 1/1 | 100% | 95% | 95% |
| 🟢 data_store | 2/2 | 2/2 | 0/0 | 100% | 95% | 95% |
| 🟢 database | 8/8 | 9/9 | 0/0 | 100% | 95% | 95% |
| 🟢 extensions | 4/4 | 4/4 | 1/1 | 100% | 95% | 95% |
| 🟢 loghelper | 1/1 | 1/1 | 0/0 | 100% | 95% | 95% |
| 🟢 notifier | 2/2 | 2/2 | 0/0 | 100% | 95% | 95% |
| 🟢 octoprint_compat | 10/10 | 0/0 | 0/0 | 100% | 95% | 95% |
| 🟢 proc_stats | 1/1 | 1/1 | 2/2 | 100% | 95% | 95% |
| 🟢 server | 3/3 | 3/3 | 4/4 | 100% | 95% | 95% |
| 🟢 websockets | 2/2 | 2/2 | 0/0 | 100% | 95% | 95% |
| 🟢 zeroconf | 1/1 | 0/0 | 0/0 | 100% | 95% | 95% |

> **Overall weighted progress: 82%**
>
> - **Surface**: API endpoint/method/notification shape coverage
> - **Depth**: how much of the internal implementation is real (not stubbed)
> - **Combined**: Surface × Depth — the effective completeness of each component
> - **Overall**: weighted by API item count per component
> - **Conformance**: 54/54 events pass normalized equality against vendored Moonraker 9008485
> - **Memory**: phobos daemon RSS ~5.4 MB vs stock Moonraker ~80-150 MB (1 thread, VmSize 7992 kB)
