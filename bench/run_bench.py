#!/usr/bin/env python3
"""SC-06b serial timing harness.

Runs `dbt run` N times per (target, model), reads per-node `execution_time`
from target/run_results.json, drops run #1 as cold, and reports warm
mean/median/p95 plus the Snowflake-vs-Redshift delta against the 25% threshold.

Usage:
    uv run python bench/run_bench.py \
        --models model_a model_b \
        --runs 6 \
        --sf-target snowflake \
        --rs-target redshift_serverless

Assumes connection env vars are set (see .env.example) and you run from the
project root so `--profiles-dir .` finds profiles.yml.
"""
import argparse
import json
import os
import statistics as stats
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RUN_RESULTS = ROOT / "target" / "run_results.json"


def dbt_run(target: str, model: str) -> None:
    """Invoke one dbt build of a single model against one target."""
    cmd = [
        "dbt", "run",
        "--profiles-dir", str(ROOT),
        "--project-dir", str(ROOT),
        "--target", target,
        "--select", model,
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        sys.stderr.write(proc.stdout + proc.stderr)
        raise SystemExit(f"dbt run failed for {model} on {target}")


def read_execution_time(model: str) -> float:
    """Pull the model node's execution_time (seconds) from run_results.json."""
    data = json.loads(RUN_RESULTS.read_text())
    for res in data["results"]:
        # unique_id looks like 'model.snowflake_poc.model_a'
        if res["unique_id"].split(".")[-1] == model:
            return float(res["execution_time"])
    raise KeyError(f"{model} not found in run_results.json")


def time_model(target: str, model: str, runs: int) -> dict:
    times = []
    for i in range(runs):
        dbt_run(target, model)
        t = read_execution_time(model)
        times.append(t)
        tag = "cold" if i == 0 else f"warm{i}"
        print(f"    {target:<22} {model:<28} {tag:<6} {t:8.3f}s")
    warm = times[1:] if runs > 1 else times
    return {
        "cold_s": round(times[0], 3),
        "warm_mean_s": round(stats.mean(warm), 3),
        "warm_median_s": round(stats.median(warm), 3),
        "warm_p95_s": round(sorted(warm)[max(0, int(len(warm) * 0.95) - 1)], 3),
        "n_warm": len(warm),
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", nargs="+", required=True)
    ap.add_argument("--runs", type=int, default=6)
    ap.add_argument("--sf-target", default="snowflake")
    ap.add_argument("--rs-target", default="redshift_serverless")
    ap.add_argument("--threshold", type=float, default=0.25,
                    help="SC-06b: Snowflake must be at least this fraction faster")
    args = ap.parse_args()

    rows = []
    for model in args.models:
        print(f"\n=== {model} ===")
        rs = time_model(args.rs_target, model, args.runs)
        sf = time_model(args.sf_target, model, args.runs)
        rs_med, sf_med = rs["warm_median_s"], sf["warm_median_s"]
        delta = (rs_med - sf_med) / rs_med if rs_med else float("nan")
        rows.append({
            "model": model,
            "rs_warm_median_s": rs_med,
            "sf_warm_median_s": sf_med,
            "sf_faster_pct": round(delta * 100, 1),
            "meets_threshold": delta >= args.threshold,
            "rs_cold_s": rs["cold_s"],
            "sf_cold_s": sf["cold_s"],
        })

    print("\n\n========== SC-06b RESULTS (warm median) ==========")
    hdr = f"{'model':<28}{'RS s':>10}{'SF s':>10}{'SF faster':>12}{'>=25%?':>9}"
    print(hdr)
    print("-" * len(hdr))
    for r in rows:
        print(f"{r['model']:<28}{r['rs_warm_median_s']:>10.3f}"
              f"{r['sf_warm_median_s']:>10.3f}{r['sf_faster_pct']:>11.1f}%"
              f"{('YES' if r['meets_threshold'] else 'no'):>9}")

    out = ROOT / "bench" / "results_serial.json"
    out.write_text(json.dumps(rows, indent=2))
    print(f"\nWrote {out}")


if __name__ == "__main__":
    main()
