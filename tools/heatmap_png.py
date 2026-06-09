#!/usr/bin/env python3
"""Render the API coverage heatmap (docs/api/COVERAGE_HEATMAP.md) as a PNG.

Parses the per-component table out of the Markdown (the maintained source of
truth) and draws a Surface / Depth / Combined heatmap — green = complete, red =
missing — with the coverage fractions annotated. Pure matplotlib; no seaborn.

Usage:
    python tools/heatmap_png.py [docs/api/COVERAGE_HEATMAP.md] [docs/api/coverage_heatmap.png]
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.colors import LinearSegmentedColormap

ROW_RE = re.compile(
    r"^\|\s*[^\w]*\s*([a-z_]+)\s*\|\s*(\d+)/(\d+)\s*\|\s*(\d+)/(\d+)\s*\|\s*(\d+)/(\d+)\s*\|"
    r"\s*(\d+)%\s*\|\s*(\d+)%\s*\|\s*(\d+)%\s*\|"
)


def parse(md: str):
    rows = []
    for line in md.splitlines():
        m = ROW_RE.match(line)
        if not m:
            continue
        name = m.group(1)
        ep_n, ep_d = int(m.group(2)), int(m.group(3))
        me_n, me_d = int(m.group(4)), int(m.group(5))
        no_n, no_d = int(m.group(6)), int(m.group(7))
        surface, depth, combined = int(m.group(8)), int(m.group(9)), int(m.group(10))
        items = ep_d + me_d + no_d  # API items for weighting / sizing
        rows.append({"name": name, "items": items, "endpoints": (ep_n, ep_d),
                     "surface": surface, "depth": depth, "combined": combined})
    return rows


def render(rows, out_path: str):
    # Sort by combined desc, then by item count desc, so the eye lands on gaps.
    rows = sorted(rows, key=lambda r: (r["combined"], r["items"]), reverse=True)
    names = [r["name"] for r in rows]
    cols = ["Surface", "Depth", "Combined"]
    data = [[r["surface"], r["depth"], r["combined"]] for r in rows]

    # Moonraker-ish green→amber→red ramp.
    cmap = LinearSegmentedColormap.from_list(
        "cov", ["#b91c1c", "#dc2626", "#f59e0b", "#84cc16", "#16a34a"])

    n = len(rows)
    fig, ax = plt.subplots(figsize=(7.2, max(6.0, n * 0.34)), dpi=160)
    im = ax.imshow(data, cmap=cmap, vmin=0, vmax=100, aspect="auto")

    ax.set_xticks(range(len(cols)))
    ax.set_xticklabels(cols, fontsize=11, fontweight="bold")
    ax.xaxis.set_ticks_position("top")
    ax.xaxis.set_label_position("top")
    ax.set_yticks(range(n))
    ax.set_yticklabels([f"{r['name']}  ({r['endpoints'][1]} ep)" for r in rows], fontsize=8)
    ax.set_xticks([x - 0.5 for x in range(len(cols) + 1)], minor=True)
    ax.set_yticks([y - 0.5 for y in range(n + 1)], minor=True)
    ax.grid(which="minor", color="white", linewidth=1.4)
    ax.tick_params(which="minor", length=0)
    ax.tick_params(which="major", length=0)

    for i in range(n):
        for j in range(3):
            v = data[i][j]
            ax.text(j, i, f"{v}%", ha="center", va="center",
                    color="white" if (v < 35 or v >= 88) else "#1f2937",
                    fontsize=8, fontweight="bold")

    # Headline number: API-item-weighted combined completeness.
    tot = sum(r["items"] for r in rows) or 1
    weighted = sum(r["combined"] * r["items"] for r in rows) / tot
    surf = sum(r["surface"] * r["items"] for r in rows) / tot
    ax.set_title(
        f"phobos API coverage vs Moonraker\nsurface {surf:.0f}% · weighted depth/combined {weighted:.0f}% · {len(rows)} components",
        fontsize=12, fontweight="bold", pad=26)

    cbar = fig.colorbar(im, ax=ax, fraction=0.025, pad=0.02)
    cbar.set_label("coverage %", fontsize=9)
    fig.tight_layout()
    fig.savefig(out_path, bbox_inches="tight", facecolor="white")
    print(f"wrote {out_path}  ({n} components, surface {surf:.0f}%, weighted {weighted:.0f}%)")


def main(argv=None):
    argv = argv or sys.argv[1:]
    md_path = argv[0] if argv else "docs/api/COVERAGE_HEATMAP.md"
    out_path = argv[1] if len(argv) > 1 else "docs/api/coverage_heatmap.png"
    rows = parse(Path(md_path).read_text())
    if not rows:
        print("no component rows parsed", file=sys.stderr)
        return 1
    render(rows, out_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
