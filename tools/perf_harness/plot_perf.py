#!/usr/bin/env python3
"""Render the phobos vs Moonraker performance graphs into docs/perf/.

Data points are the measured results from the vegeta sweeps documented in
docs/PERFORMANCE.md (Klippy stubbed, same 32-core host). Re-run after a fresh
benchmark by updating the dicts below. Output: docs/perf/*.png.
"""
import os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

OUT = os.path.join(os.path.dirname(__file__), "..", "..", "docs", "perf")
os.makedirs(OUT, exist_ok=True)

PHOBOS = "#2563eb"   # blue
MOON = "#dc2626"     # red
GREEN = "#16a34a"

# server.info sweep: offered rate -> (throughput req/s, p50 ms)
info_phobos = {5000: (5000, 0.05), 10000: (10000, 0.05), 20000: (19997, 0.07),
               40000: (39972, 0.06), 80000: (79976, 0.05), 120000: (17320, 24.08)}
info_moon = {5000: (5000, 0.37), 10000: (6767, 262.84), 20000: (5204, 270.94),
             40000: (4334, 256.71), 80000: (6146, 225.87)}


def _style(ax):
    ax.grid(True, ls="--", alpha=0.35)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)


# --- 1. Throughput vs offered load -----------------------------------------
fig, ax = plt.subplots(figsize=(7, 4.3))
xs = sorted(info_phobos)
ax.plot(xs, [info_phobos[x][0] for x in xs], "o-", color=PHOBOS, lw=2.2, label="phobos")
xm = sorted(info_moon)
ax.plot(xm, [info_moon[x][0] for x in xm], "s-", color=MOON, lw=2.2, label="Moonraker")
ax.plot([0, 80000], [0, 80000], ":", color="#94a3b8", lw=1.3, label="ideal (keeps up)")
ax.set_xlabel("offered req/s")
ax.set_ylabel("served req/s")
ax.set_title("server.info — throughput vs offered load (Klippy stubbed)")
ax.legend(frameon=False)
_style(ax)
fig.tight_layout(); fig.savefig(os.path.join(OUT, "throughput_vs_load.png"), dpi=130)
plt.close(fig)

# --- 2. p50 latency vs offered load (log y) --------------------------------
fig, ax = plt.subplots(figsize=(7, 4.3))
ax.plot(xs, [info_phobos[x][1] for x in xs], "o-", color=PHOBOS, lw=2.2, label="phobos")
ax.plot(xm, [info_moon[x][1] for x in xm], "s-", color=MOON, lw=2.2, label="Moonraker")
ax.set_yscale("log")
ax.set_xlabel("offered req/s")
ax.set_ylabel("p50 latency (ms, log)")
ax.set_title("server.info — response time vs load: where Moonraker's loop backs up")
ax.axvspan(7000, 11000, color=MOON, alpha=0.08)
ax.annotate("Moonraker saturates\n(0.37 → 263 ms)", xy=(10000, 263), xytext=(22000, 60),
            color=MOON, fontsize=9, arrowprops=dict(arrowstyle="->", color=MOON))
ax.legend(frameon=False)
_style(ax)
fig.tight_layout(); fig.savefig(os.path.join(OUT, "latency_vs_load.png"), dpi=130)
plt.close(fig)

# --- 3. objects.query optimisation journey ---------------------------------
fig, ax = plt.subplots(figsize=(7, 4.3))
stages = ["original", "+smp_alloc", "+off-Core\n+no-copy"]
thru = [1067, 2160, 3959]
bars = ax.bar(stages, thru, color=[MOON, "#f59e0b", GREEN], width=0.6)
for b, v in zip(bars, thru):
    ax.text(b.get_x() + b.get_width() / 2, v + 60, f"{v}/s", ha="center", fontsize=10, weight="bold")
ax.set_ylabel("objects.query req/s (sustained)")
ax.set_title("objects.query — optimisation journey (Klippy proxy path)")
ax.set_ylim(0, 4600)
_style(ax)
fig.tight_layout(); fig.savefig(os.path.join(OUT, "query_journey.png"), dpi=130)
plt.close(fig)

# --- 4. RSS + per-endpoint latency comparison ------------------------------
fig, (a1, a2) = plt.subplots(1, 2, figsize=(10, 4.2))
a1.bar(["phobos\nidle", "phobos\npost-spike", "Moonraker\nidle"], [3.4, 9.5, 57.0],
       color=[PHOBOS, "#60a5fa", MOON], width=0.6)
for i, v in enumerate([3.4, 9.5, 57.0]):
    a1.text(i, v + 1, f"{v} MB", ha="center", fontsize=10, weight="bold")
a1.set_ylabel("RSS (MB)")
a1.set_title("Resident memory")
_style(a1)

eps = ["info", "config", "system_info"]
p_lat = [0.05, 0.06, 0.06]
m_lat = [0.43, 0.48, 0.22]
x = range(len(eps))
a2.bar([i - 0.2 for i in x], p_lat, width=0.4, color=PHOBOS, label="phobos")
a2.bar([i + 0.2 for i in x], m_lat, width=0.4, color=MOON, label="Moonraker")
a2.set_xticks(list(x)); a2.set_xticklabels(eps)
a2.set_ylabel("p50 latency (ms)")
a2.set_title("Local-read latency (at matched load)")
a2.legend(frameon=False)
_style(a2)
fig.tight_layout(); fig.savefig(os.path.join(OUT, "memory_and_latency.png"), dpi=130)
plt.close(fig)

print("wrote 4 graphs to docs/perf/")
