#!/usr/bin/env python3
"""Combine matched A/B capture directories into a single summary.

Each input directory is a run_windows_ab.ps1 (or run_windows_typing.ps1)
results directory with summary.json, samples.csv, and steps.csv. The combined
output recomputes per-arm summaries over every measured process and
concatenates each capture's per-pair percentage changes (the pairs inside a
capture are the matched baseline/candidate processes).
"""

import argparse
import csv
import json
import os
import statistics


def pct(values, p):
    if not values:
        return 0.0
    ordered = sorted(values)
    index = int(p * (len(ordered) - 1))
    return ordered[max(0, min(index, len(ordered) - 1))]


def series(values):
    ordered = sorted(values)
    return {
        "count": len(ordered),
        "min": ordered[0] if ordered else 0,
        "p50": pct(ordered, 0.50),
        "p95": pct(ordered, 0.95),
        "max": ordered[-1] if ordered else 0,
    }


def load(path):
    with open(path, encoding="utf-8-sig") as handle:
        return json.load(handle)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--kind", choices=("sequence", "typing"), required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("directories", nargs="+")
    args = parser.parse_args()

    os.makedirs(args.out, exist_ok=True)
    captures = [load(os.path.join(directory, "summary.json")) for directory in args.directories]

    metrics = list(captures[0]["summaries"]["baseline"].keys())
    samples = []
    for directory, capture in zip(args.directories, captures):
        for sample in capture["samples"]:
            if str(sample.get("run", "")).startswith("warmup"):
                continue
            sample = dict(sample)
            sample["capture"] = os.path.basename(os.path.normpath(directory))
            samples.append(sample)

    combined = {
        "schema": 1,
        "kind": args.kind,
        "captures": [
            {"directory": os.path.basename(os.path.normpath(d)), "pairs": c.get("runs_per_candidate", 0)}
            for d, c in zip(args.directories, captures)
        ],
        "summaries": {},
        "paired_comparison": {},
        "step_summaries": {},
        "step_paired_comparison": {},
        "samples": samples,
    }

    for arm in ("baseline", "candidate"):
        combined["summaries"][arm] = {}
        for metric in metrics:
            values = [float(sample[metric]) for sample in samples if sample["candidate"] == arm]
            combined["summaries"][arm][metric] = series(values)

    for metric in metrics:
        changes = []
        for capture in captures:
            changes.extend(capture["paired_comparison"][metric]["changes"])
        combined["paired_comparison"][metric] = {
            "median_percent_change": statistics.median(changes) if changes else 0.0,
            "changes": changes,
        }

    # Merge per-step rows and per-pair step changes.
    step_rows = []
    for directory in args.directories:
        with open(os.path.join(directory, "steps.csv"), encoding="utf-8-sig") as handle:
            for row in csv.DictReader(handle):
                if str(row["run"]).startswith("warmup"):
                    continue
                row["capture"] = os.path.basename(os.path.normpath(directory))
                step_rows.append(row)

    step_count = 24 if args.kind == "typing" else 9
    for step in range(step_count):
        key = f"step_{step}"
        combined["step_summaries"][key] = {}
        for arm in ("baseline", "candidate"):
            combined["step_summaries"][key][arm] = {}
            arm_rows = [r for r in step_rows if r["candidate"] == arm and int(r["step"]) == step]
            for field in ("action_ns", "build_ns", "builds"):
                values = [float(r[field]) for r in arm_rows]
                combined["step_summaries"][key][arm][field] = series(values)
        combined["step_paired_comparison"][key] = {}
        for field in ("action_ns", "build_ns"):
            changes = []
            for capture in captures:
                changes.extend(capture["step_paired_comparison"][key][field]["changes"])
            combined["step_paired_comparison"][key][field] = {
                "median_percent_change": statistics.median(changes) if changes else 0.0,
                "changes": changes,
            }

    with open(os.path.join(args.out, "summary.json"), "w", encoding="utf-8") as handle:
        json.dump(combined, handle, indent=2)

    # CSV copies for convenient diffing.
    keys = [
        "capture", "candidate", "run", "exit_code", "elapsed_ns", "cpu_total_ns",
        "peak_working_set_bytes", "application_build_ns", "application_build_max_ns",
        "first_application_submit_ns", "host_wall_ns", "gpu_submissions",
    ]
    keys.append("typing_build_ns" if args.kind == "typing" else "sequence_build_ns")
    if args.kind == "typing":
        keys.extend(("typing_startup_ns", "typing_setup_ns", "typing_tail_ns"))
    keys.append("log")
    with open(os.path.join(args.out, "samples.csv"), "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=keys, extrasaction="ignore")
        writer.writeheader()
        for sample in samples:
            writer.writerow(sample)

    with open(os.path.join(args.out, "steps.csv"), "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(
            handle, fieldnames=["capture", "candidate", "run", "step", "action_ns", "build_ns", "builds"],
            extrasaction="ignore",
        )
        writer.writeheader()
        for row in step_rows:
            writer.writerow(row)

    # Human-readable compact tables.
    with open(os.path.join(args.out, "metrics.csv"), "w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow([
            "metric", "baseline_count", "baseline_min", "baseline_p50", "baseline_p95",
            "baseline_max", "candidate_count", "candidate_min", "candidate_p50",
            "candidate_p95", "candidate_max", "paired_median_percent_change", "pair_changes",
        ])
        for metric in metrics:
            base = combined["summaries"]["baseline"][metric]
            cand = combined["summaries"]["candidate"][metric]
            pair = combined["paired_comparison"][metric]
            writer.writerow([
                metric, base["count"], base["min"], base["p50"], base["p95"], base["max"],
                cand["count"], cand["min"], cand["p50"], cand["p95"], cand["max"],
                pair["median_percent_change"], ";".join(f"{value:.4f}" for value in pair["changes"]),
            ])

    with open(os.path.join(args.out, "step-table.csv"), "w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow([
            "step", "baseline_build_p50", "candidate_build_p50", "paired_build_median_percent",
            "baseline_builds_p50", "candidate_builds_p50", "baseline_action_p50",
            "candidate_action_p50", "paired_action_median_percent",
        ])
        for step in range(step_count):
            key = f"step_{step}"
            step_summary = combined["step_summaries"][key]
            paired = combined["step_paired_comparison"][key]
            writer.writerow([
                step,
                step_summary["baseline"]["build_ns"]["p50"],
                step_summary["candidate"]["build_ns"]["p50"],
                paired["build_ns"]["median_percent_change"],
                step_summary["baseline"]["builds"]["p50"],
                step_summary["candidate"]["builds"]["p50"],
                step_summary["baseline"]["action_ns"]["p50"],
                step_summary["candidate"]["action_ns"]["p50"],
                paired["action_ns"]["median_percent_change"],
            ])

    print(f"combined {len(samples)} processes from {len(captures)} captures")
    for metric in metrics:
        base = combined["summaries"]["baseline"][metric]
        cand = combined["summaries"]["candidate"][metric]
        pair = combined["paired_comparison"][metric]
        print(f"  {metric}: base p50 {base['p50']:.3f} cand p50 {cand['p50']:.3f} "
              f"paired {pair['median_percent_change']:.2f}%")


if __name__ == "__main__":
    main()
