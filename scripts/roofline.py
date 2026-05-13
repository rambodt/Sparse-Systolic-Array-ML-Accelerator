#!/usr/bin/env python3
"""
Roofline analysis for the Sparse Systolic Array Matrix Accelerator.

Reads simulation results from a CSV file (see sample_results.csv) and produces:
  1. Roofline plot — achieved GOPS vs arithmetic intensity, with compute and
     memory-bandwidth ceilings.
  2. PE utilization bar chart — with and without the sparsity-skip benefit.
  3. Metrics table printed to stdout.

All formulas from Section 14.2 of the Architecture Design Document.

Usage:
  python roofline.py                                 # uses sample_results.csv
  python roofline.py --csv my_sim_results.csv
  python roofline.py --fmax 150 --array-size 16
  python roofline.py --no-plot                       # table only
"""

import argparse
import csv
import math
import os
import sys

import numpy as np

# ── Design constants ──────────────────────────────────────────────────────────
ARRAY_SIZE  = 16   # PE grid dimension (square)
DATA_WIDTH  = 8    # bits per activation / weight
ACC_WIDTH   = 32   # accumulator width
TILE_SIZE   = ARRAY_SIZE

# ── Metric formulas (Section 14.2) ───────────────────────────────────────────

def peak_gops(array_size: int, fmax_hz: float) -> float:
    """Peak compute throughput in GOPS."""
    return array_size * array_size * 2 * fmax_hz / 1e9


def scratchpad_bandwidth_gbps(array_size: int, data_width: int, fmax_hz: float) -> float:
    """Peak scratchpad read bandwidth in GB/s (one activation + one weight per PE column per cycle)."""
    return (data_width / 8) * array_size * 2 * fmax_hz / 1e9


def arithmetic_intensity(M: int, K: int, N: int, data_width: int) -> float:
    """Arithmetic intensity in ops/byte."""
    ops   = 2 * M * K * N
    bytes_ = (M * K + K * N) * (data_width / 8)
    return ops / bytes_


def achieved_gops(M: int, K: int, N: int, total_cycles: int, fmax_hz: float) -> float:
    """Achieved performance in GOPS."""
    if total_cycles == 0:
        return 0.0
    ops = 2 * M * K * N
    return ops / total_cycles / 1e9 * fmax_hz


def pe_utilization(achieved: float, peak: float) -> float:
    """PE utilization as percentage."""
    return 100.0 * achieved / peak if peak > 0 else 0.0


def effective_gops_with_sparsity(achieved: float, skip_rate: float) -> float:
    """
    Effective GOPS accounting for sparsity — represents useful work done
    per unit time. Higher is better when workload has true zeros.
    """
    denom = 1.0 - skip_rate
    return achieved / denom if denom > 0 else achieved


def skip_rate(skipped_cycles: int, total_cycles: int) -> float:
    """Fraction of cycles where at least one row was skipped."""
    return skipped_cycles / total_cycles if total_cycles > 0 else 0.0


# ── CSV loading ───────────────────────────────────────────────────────────────

def load_csv(path: str) -> list[dict]:
    rows = []
    with open(path) as f:
        reader = csv.DictReader(row for row in f if not row.startswith("#"))
        for r in reader:
            rows.append({
                "name":           r["name"].strip(),
                "M":              int(r["M"]),
                "K":              int(r["K"]),
                "N":              int(r["N"]),
                "sparsity":       float(r["sparsity"]),
                "total_cycles":   int(r["total_cycles"]),
                "skipped_cycles": int(r["skipped_cycles"]),
                "fmax_hz":        float(r["fmax_mhz"]) * 1e6,
            })
    return rows


# ── Metrics computation ───────────────────────────────────────────────────────

def compute_metrics(rows: list[dict], array_size: int, data_width: int) -> list[dict]:
    out = []
    for r in rows:
        fmax = r["fmax_hz"]
        peak  = peak_gops(array_size, fmax)
        bw    = scratchpad_bandwidth_gbps(array_size, data_width, fmax)
        ai    = arithmetic_intensity(r["M"], r["K"], r["N"], data_width)
        ach   = achieved_gops(r["M"], r["K"], r["N"], r["total_cycles"], fmax)
        sr    = skip_rate(r["skipped_cycles"], r["total_cycles"])
        eff   = effective_gops_with_sparsity(ach, sr)
        util  = pe_utilization(ach, peak)
        util_eff = pe_utilization(eff, peak)
        ridge = peak / bw  # AI at which compute ceiling = memory ceiling

        out.append({
            **r,
            "peak_gops":      peak,
            "bw_gbps":        bw,
            "ai":             ai,
            "achieved_gops":  ach,
            "effective_gops": eff,
            "skip_rate":      sr,
            "util_pct":       util,
            "util_eff_pct":   util_eff,
            "ridge_point":    ridge,
            "memory_bound":   ai < ridge,
        })
    return out


# ── Table output ──────────────────────────────────────────────────────────────

def print_table(metrics: list[dict]) -> None:
    hdr = (
        f"{'Workload':<20} {'M':>5} {'K':>5} {'N':>5}  "
        f"{'AI':>8}  {'Achieved':>10}  {'Effective':>10}  "
        f"{'Util%':>7}  {'Util%(eff)':>10}  {'Skip%':>7}  {'Bound':<10}"
    )
    sep = "-" * len(hdr)

    print()
    print("Roofline Analysis — Sparse Systolic Array Accelerator")
    print(sep)
    print(hdr)
    print(sep)

    for m in metrics:
        bound = "memory" if m["memory_bound"] else "compute"
        print(
            f"{m['name']:<20} {m['M']:>5} {m['K']:>5} {m['N']:>5}  "
            f"{m['ai']:>7.1f}x  {m['achieved_gops']:>9.2f}G  {m['effective_gops']:>9.2f}G  "
            f"{m['util_pct']:>6.1f}%  {m['util_eff_pct']:>9.1f}%  {m['skip_rate']*100:>6.1f}%  {bound:<10}"
        )

    print(sep)
    m0 = metrics[0]
    print(f"  Peak compute:        {m0['peak_gops']:.1f} GOPS  "
          f"({int(m0['fmax_hz']/1e6)} MHz x {ARRAY_SIZE}x{ARRAY_SIZE} array x 2 MACs/cycle)")
    print(f"  Scratchpad BW:       {m0['bw_gbps']:.1f} GB/s")
    print(f"  Ridge point:         AI = {m0['ridge_point']:.1f} ops/byte")
    print(sep)
    print("  Columns: AI = ops/byte | Achieved/Effective in GOPS | Util% = Achieved/Peak")
    print()


# ── Plotting ──────────────────────────────────────────────────────────────────

def plot(metrics: list[dict], out_dir: str) -> None:
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        import matplotlib.patches as mpatches
    except ImportError:
        print("matplotlib not installed — skipping plots (pip install matplotlib)")
        return

    os.makedirs(out_dir, exist_ok=True)
    m0 = metrics[0]
    peak = m0["peak_gops"]
    bw   = m0["bw_gbps"]
    ridge = m0["ridge_point"]

    # ── Figure 1: Roofline ────────────────────────────────────────────────────
    fig, ax = plt.subplots(figsize=(10, 6))

    ai_range = np.logspace(-1, 3, 500)
    mem_ceil  = bw * ai_range
    comp_ceil = np.full_like(ai_range, peak)
    roof      = np.minimum(mem_ceil, comp_ceil)

    ax.loglog(ai_range, roof, "k-", linewidth=2.5, label="Roofline")
    ax.axvline(ridge, color="gray", linestyle="--", linewidth=1, alpha=0.6)
    ax.text(ridge * 1.05, peak * 0.5, f"Ridge\n{ridge:.0f} ops/B",
            fontsize=8, color="gray", va="center")

    colors_mb = "#e07b54"   # orange-red for memory-bound
    colors_cb = "#4c72b0"   # blue for compute-bound

    for m in metrics:
        color = colors_mb if m["memory_bound"] else colors_cb
        ax.scatter(m["ai"], m["achieved_gops"], color=color, s=80, zorder=5)
        ax.annotate(m["name"], (m["ai"], m["achieved_gops"]),
                    textcoords="offset points", xytext=(6, 4), fontsize=7.5)

        if m["skip_rate"] > 0:
            ax.scatter(m["ai"], m["effective_gops"], color=color,
                       s=80, marker="^", zorder=5, alpha=0.75)
            ax.plot([m["ai"], m["ai"]],
                    [m["achieved_gops"], m["effective_gops"]],
                    color=color, linewidth=1, linestyle=":", alpha=0.7)

    ax.set_xlabel("Arithmetic Intensity (ops / byte)", fontsize=11)
    ax.set_ylabel("Performance (GOPS)", fontsize=11)
    ax.set_title(f"Roofline — 16×16 Systolic Array  ({int(m0['fmax_hz']/1e6)} MHz, INT8)",
                 fontsize=12, fontweight="bold")

    mem_patch  = mpatches.Patch(color=colors_mb, label="Memory-bound")
    comp_patch = mpatches.Patch(color=colors_cb, label="Compute-bound")
    tri_patch  = plt.Line2D([0], [0], marker="^", color="w", markerfacecolor="gray",
                             markersize=8, label="Effective GOPS (sparsity)")
    ax.legend(handles=[mem_patch, comp_patch, tri_patch], fontsize=9)

    ax.set_xlim(0.5, 1000)
    ax.set_ylim(0.1, peak * 3)
    ax.grid(True, which="both", linestyle="--", linewidth=0.5, alpha=0.5)

    path1 = os.path.join(out_dir, "roofline.png")
    fig.tight_layout()
    fig.savefig(path1, dpi=150)
    plt.close(fig)
    print(f"Saved: {path1}")

    # ── Figure 2: PE Utilization bar chart ────────────────────────────────────
    fig, ax = plt.subplots(figsize=(11, 5))
    names  = [m["name"] for m in metrics]
    utils  = [m["util_pct"] for m in metrics]
    utils_e = [m["util_eff_pct"] for m in metrics]

    x = np.arange(len(names))
    w = 0.38
    bars1 = ax.bar(x - w/2, utils,   width=w, color=colors_cb, label="PE Utilization (dense)")
    bars2 = ax.bar(x + w/2, utils_e, width=w, color="#55a868", label="PE Utilization (with sparsity)")

    for bar in bars1:
        h = bar.get_height()
        ax.text(bar.get_x() + bar.get_width()/2, h + 0.3, f"{h:.1f}%",
                ha="center", va="bottom", fontsize=7.5)
    for bar in bars2:
        h = bar.get_height()
        ax.text(bar.get_x() + bar.get_width()/2, h + 0.3, f"{h:.1f}%",
                ha="center", va="bottom", fontsize=7.5)

    ax.set_xticks(x)
    ax.set_xticklabels(names, rotation=25, ha="right", fontsize=9)
    ax.set_ylabel("PE Utilization (%)", fontsize=11)
    ax.set_title("PE Utilization by Workload — Dense vs. Sparsity-Adjusted",
                 fontsize=12, fontweight="bold")
    ax.set_ylim(0, max(utils_e) * 1.25)
    ax.axhline(100, color="red", linestyle="--", linewidth=1, alpha=0.4, label="Peak (100%)")
    ax.legend(fontsize=9)
    ax.grid(axis="y", linestyle="--", linewidth=0.5, alpha=0.5)

    path2 = os.path.join(out_dir, "pe_utilization.png")
    fig.tight_layout()
    fig.savefig(path2, dpi=150)
    plt.close(fig)
    print(f"Saved: {path2}")


# ── Entry point ───────────────────────────────────────────────────────────────

def main():
    default_csv = os.path.join(os.path.dirname(__file__), "sample_results.csv")

    parser = argparse.ArgumentParser(
        description="Roofline analysis for the Sparse Systolic Array Accelerator",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python roofline.py
  python roofline.py --csv my_sim.csv
  python roofline.py --fmax 150 --no-plot
""")
    parser.add_argument("--csv", default=default_csv,
                        help="Path to simulation results CSV (default: sample_results.csv)")
    parser.add_argument("--array-size", type=int, default=ARRAY_SIZE)
    parser.add_argument("--data-width", type=int, default=DATA_WIDTH)
    parser.add_argument("--fmax",       type=float, default=None,
                        help="Override Fmax in MHz for all workloads")
    parser.add_argument("--out-dir",    default="scripts/plots",
                        help="Directory for output plots")
    parser.add_argument("--no-plot",    action="store_true",
                        help="Print table only, skip matplotlib")
    args = parser.parse_args()

    if not os.path.exists(args.csv):
        print(f"Error: CSV file not found: {args.csv}", file=sys.stderr)
        sys.exit(1)

    rows = load_csv(args.csv)

    if args.fmax is not None:
        for r in rows:
            r["fmax_hz"] = args.fmax * 1e6

    metrics = compute_metrics(rows, args.array_size, args.data_width)
    print_table(metrics)

    if not args.no_plot:
        plot(metrics, args.out_dir)


if __name__ == "__main__":
    main()
