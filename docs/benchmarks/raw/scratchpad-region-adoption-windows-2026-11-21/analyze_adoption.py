#!/usr/bin/env python3
"""Combine primary + confirmation captures for the issue #231 adoption record.

Reads samples.csv / steps.csv / counters.csv from the primary directory and
its sibling "<scenario>-confirmation" directory, relabels rounds as p01..p07
and c01..c03, and writes combined CSVs plus a JSON summary with the same
metric shape the PowerShell runner emits (paired medians for plain->adopted,
adopted->quickopen, plain->quickopen).

No tuning: every accepted sample is retained, including candidate stalls.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
from pathlib import Path

ARMS = ("plain", "adopted", "quickopen")
COMPARISONS = (
    ("plain", "adopted"),
    ("adopted", "quickopen"),
    ("plain", "quickopen"),
)
METRICS = (
    "elapsed_ns",
    "cpu_total_ns",
    "peak_working_set_bytes",
    "application_build_ns",
    "application_build_max_ns",
    "first_application_submit_ns",
    "host_wall_ns",
    "gpu_submissions",
    "scenario_build_ns",
    "setup_build_ns",
    "tail_build_ns",
)
COUNTER_FIELDS = (
    "emitted",
    "reused",
    "regions_skipped",
    "retained_reused",
    "reconcile_nodes",
    "layout_nodes",
    "paint_nodes",
    "composition_nodes",
    "text_shapes",
    "stage_description_ns",
    "stage_reconcile_ns",
    "query_len",
    "selected",
    "results",
)


def percentile(values: list[float], fraction: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = int(math.floor(fraction * (len(ordered) - 1)))
    return ordered[max(0, min(index, len(ordered) - 1))]


def series(values: list[float]) -> dict:
    if not values:
        return {"count": 0, "min": 0.0, "p50": 0.0, "p95": 0.0, "max": 0.0}
    return {
        "count": len(values),
        "min": min(values),
        "p50": percentile(values, 0.50),
        "p95": percentile(values, 0.95),
        "max": max(values),
    }


def to_int(value: str) -> int:
    if value is None or value == "":
        return 0
    return int(float(value))


def read_rows(path: Path, prefix: str) -> list[dict]:
    if not path.exists():
        return []
    rows: list[dict] = []
    with path.open(newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            row = dict(row)
            row["run"] = f"{prefix}{int(row['run'].split('-')[1]):02d}"
            if "attempts" in row:
                row["attempts"] = to_int(row["attempts"])
            rows.append(row)
    return rows


def write_csv(path: Path, rows: list[dict], columns: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def paired_changes(
    rows: list[dict], field: str, before: str, after: str, runs: list[str]
) -> list[float]:
    changes: list[float] = []
    for run in runs:
        a = next((r for r in rows if r["run"] == run and r["candidate"] == before), None)
        b = next((r for r in rows if r["run"] == run and r["candidate"] == after), None)
        if a is None or b is None:
            raise SystemExit(f"missing pair {run} {before}->{after} {field}")
        av = float(a[field])
        bv = float(b[field])
        if av != 0:
            changes.append((bv - av) * 100.0 / av)
    return changes


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--primary", required=True, type=Path)
    parser.add_argument("--confirmation", required=True, type=Path)
    parser.add_argument("--scenario", required=True)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--steps", required=True, type=int)
    args = parser.parse_args()

    primary = args.primary
    confirmation = args.confirmation
    out: Path = args.out
    out.mkdir(parents=True, exist_ok=True)

    samples = read_rows(primary / "samples.csv", "p") + read_rows(
        confirmation / "samples.csv", "c"
    )
    steps = read_rows(primary / "steps.csv", "p") + read_rows(
        confirmation / "steps.csv", "c"
    )
    counters = read_rows(primary / "counters.csv", "p") + read_rows(
        confirmation / "counters.csv", "c"
    )
    runs = sorted({row["run"] for row in samples})
    if len(runs) != 10:
        raise SystemExit(f"expected 10 combined rounds, found {len(runs)}")

    sample_columns = [
        "candidate",
        "run",
        "exit_code",
        "attempts",
        "elapsed_ns",
        "cpu_total_ns",
        "peak_working_set_bytes",
        "application_build_ns",
        "application_build_max_ns",
        "first_application_submit_ns",
        "host_wall_ns",
        "gpu_submissions",
        "scenario_build_ns",
        "setup_build_ns",
        "setup_builds",
        "tail_build_ns",
        "tail_builds",
        "log_file",
    ]
    write_csv(out / "samples.csv", samples, sample_columns)
    write_csv(
        out / "steps.csv",
        steps,
        ["candidate", "run", "step", "action_ns", "build_ns", "builds", "query_len"],
    )
    write_csv(
        out / "counters.csv",
        counters,
        ["candidate", "run", "step", *COUNTER_FIELDS],
    )

    summaries = {
        arm: {
            metric: series(
                [float(r[metric]) for r in samples if r["candidate"] == arm]
            )
            for metric in METRICS
        }
        for arm in ARMS
    }
    paired = {}
    for from_arm, to_arm in COMPARISONS:
        key = f"{from_arm}_to_{to_arm}"
        paired[key] = {}
        for metric in METRICS:
            changes = paired_changes(samples, metric, from_arm, to_arm, runs)
            paired[key][metric] = {
                "median_percent_change": percentile(changes, 0.50),
                "changes": changes,
            }

    step_summaries: dict[str, dict] = {}
    step_paired: dict[str, dict] = {}
    for step_index in range(args.steps):
        key = f"step_{step_index}"
        step_summaries[key] = {}
        for arm in ARMS:
            step_summaries[key][arm] = {}
            for field in ("action_ns", "build_ns", "builds"):
                values = [
                    float(r.get(field) or 0)
                    for r in steps
                    if r["candidate"] == arm and int(r["step"]) == step_index
                ]
                step_summaries[key][arm][field] = series(values)
        step_paired[key] = {}
        for field in ("action_ns", "build_ns"):
            for from_arm, to_arm in COMPARISONS:
                changes = []
                for run in runs:
                    a = next(
                        (
                            r
                            for r in steps
                            if r["run"] == run
                            and r["candidate"] == from_arm
                            and int(r["step"]) == step_index
                        ),
                        None,
                    )
                    b = next(
                        (
                            r
                            for r in steps
                            if r["run"] == run
                            and r["candidate"] == to_arm
                            and int(r["step"]) == step_index
                        ),
                        None,
                    )
                    if a is None or b is None:
                        raise SystemExit(f"missing step pair {run} {step_index}")
                    av = float(a[field])
                    if av != 0:
                        changes.append((float(b[field]) - av) * 100.0 / av)
                step_paired[key][f"{from_arm}_to_{to_arm}_{field}"] = {
                    "median_percent_change": percentile(changes, 0.50),
                    "changes": changes,
                }

    counter_summaries = {}
    if counters:
        for arm in ARMS:
            counter_summaries[arm] = {}
            for field in COUNTER_FIELDS:
                per_run = []
                for run in runs:
                    values = [
                        float(r.get(field) or 0)
                        for r in counters
                        if r["candidate"] == arm
                        and r["run"] == run
                        and 1 <= int(r["step"]) < args.steps
                    ]
                    if values:
                        per_run.append(percentile(values, 0.50))
                counter_summaries[arm][field] = series(per_run)

    per_character = {}
    if args.scenario in ("typing", "quickopen") and counters:
        for step_index in range(1, args.steps):
            row = {"step": step_index}
            for arm in ARMS:
                values = {
                    field: [
                        float(r.get(field) or 0)
                        for r in counters
                        if r["candidate"] == arm and int(r["step"]) == step_index
                    ]
                    for field in ("emitted", "regions_skipped", "results")
                }
                build_values = [
                    float(r["build_ns"])
                    for r in steps
                    if r["candidate"] == arm and int(r["step"]) == step_index
                ]
                row[f"{arm}_build_ns_p50"] = percentile(build_values, 0.50)
                for field in ("emitted", "regions_skipped", "results"):
                    row[f"{arm}_{field}_p50"] = percentile(values[field], 0.50)
            for from_arm, to_arm in COMPARISONS:
                changes = []
                for run in runs:
                    a = next(
                        (
                            r
                            for r in steps
                            if r["run"] == run
                            and r["candidate"] == from_arm
                            and int(r["step"]) == step_index
                        ),
                        None,
                    )
                    b = next(
                        (
                            r
                            for r in steps
                            if r["run"] == run
                            and r["candidate"] == to_arm
                            and int(r["step"]) == step_index
                        ),
                        None,
                    )
                    if a is not None and b is not None and float(a["build_ns"]) != 0:
                        changes.append(
                            (float(b["build_ns"]) - float(a["build_ns"]))
                            * 100.0
                            / float(a["build_ns"])
                        )
                row[f"{from_arm}_to_{to_arm}_build_percent_p50"] = percentile(
                    changes, 0.50
                )
            per_character[step_index] = row

    report = {
        "scenario": args.scenario,
        "runs": runs,
        "samples": summaries,
        "paired_comparison": paired,
        "step_summaries": step_summaries,
        "step_paired_comparison": step_paired,
        "counter_summaries": counter_summaries,
        "per_character": per_character,
        "accepted_samples": len(samples),
        "retry_samples": [
            {"run": r["run"], "candidate": r["candidate"], "attempts": r["attempts"]}
            for r in samples
            if int(r.get("attempts", 1)) > 1
        ],
    }
    (out / "combined.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(f"combined: {out / 'combined.json'}")


if __name__ == "__main__":
    main()
