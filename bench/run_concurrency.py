#!/usr/bin/env python3
"""SC-06b concurrency harness — reproduces the REAL bottleneck.

The exec summary is explicit: concurrency, not raw single-query speed, is the
problem. This launches K concurrent `dbt run` invocations (each building the
given models) against one target and measures:
  - total wall-clock for the whole concurrent batch
  - per-invocation completion time
  - degradation vs the serial baseline (run_bench.py warm median)

Run it once per target and compare how much each engine slows down under load.
Snowflake's independent virtual warehouses should degrade far less than a single
shared Redshift cluster — that's the thesis this tests.

Usage:
    uv run python bench/run_concurrency.py \
        --target redshift_serverless \
        --models model_a model_b \
        --concurrency 8
"""
import argparse
import json
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def one_invocation(target: str, models: list[str], idx: int) -> dict:
    """Run a single dbt invocation building all models; time its wall-clock.

    Each invocation uses its own --target-path so concurrent runs don't clobber
    each other's run_results.json.
    """
    target_path = ROOT / "target" / f"concurrent_{idx}"
    cmd = [
        "dbt", "run",
        "--profiles-dir", str(ROOT),
        "--project-dir", str(ROOT),
        "--target", target,
        "--target-path", str(target_path),
        "--select", *models,
    ]
    start = time.monotonic()
    proc = subprocess.run(cmd, capture_output=True, text=True)
    elapsed = time.monotonic() - start
    ok = proc.returncode == 0
    if not ok:
        sys.stderr.write(f"[invocation {idx}] FAILED\n{proc.stdout}{proc.stderr}\n")
    return {"idx": idx, "elapsed_s": round(elapsed, 3), "ok": ok}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", required=True)
    ap.add_argument("--models", nargs="+", required=True)
    ap.add_argument("--concurrency", type=int, default=8,
                    help="number of simultaneous dbt invocations")
    args = ap.parse_args()

    print(f"Launching {args.concurrency} concurrent invocations on "
          f"'{args.target}' building {args.models}...")

    batch_start = time.monotonic()
    results = []
    with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        futures = [
            pool.submit(one_invocation, args.target, args.models, i)
            for i in range(args.concurrency)
        ]
        for fut in as_completed(futures):
            results.append(fut.result())
    batch_wall = time.monotonic() - batch_start

    results.sort(key=lambda r: r["idx"])
    per = [r["elapsed_s"] for r in results if r["ok"]]
    print("\n========== SC-06b CONCURRENCY RESULTS ==========")
    print(f"target              : {args.target}")
    print(f"concurrency         : {args.concurrency}")
    print(f"total wall-clock    : {batch_wall:.3f}s")
    print(f"failures            : {sum(not r['ok'] for r in results)}")
    if per:
        print(f"per-invocation min  : {min(per):.3f}s")
        print(f"per-invocation max  : {max(per):.3f}s")
        print(f"per-invocation mean : {sum(per)/len(per):.3f}s")
    print("\nCompare each invocation's mean against run_bench.py's warm median:")
    print("  degradation = (concurrent_mean - serial_median) / serial_median")

    out = ROOT / "bench" / f"results_concurrency_{args.target}.json"
    out.write_text(json.dumps(
        {"target": args.target, "concurrency": args.concurrency,
         "total_wall_s": round(batch_wall, 3), "invocations": results},
        indent=2))
    print(f"\nWrote {out}")


if __name__ == "__main__":
    main()
