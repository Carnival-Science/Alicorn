#!/usr/bin/env python3
"""Extract per-step Frame_Stats counter deltas from benchmark logs.

The diagnostic hook prints one cumulative-snapshot delta line per step:
    alicorn-performance-sequence-counters step N emitted ... 
or, for the typing burst,
    alicorn-performance-typing-counters step N emitted ...

This tool parses every run log in each arm directory, takes the median of each
field at each step, and writes the common-arm table plus the candidate-only
extended table (phase-2 reuse, splice, sparse layout, stage timings).
"""

import argparse
import glob
import os
import statistics


COMMON_FIELDS = [
    "emitted", "reused", "regions_skipped", "retained_reused", "reconcile_nodes",
    "layout_nodes", "paint_nodes", "composition_nodes", "measure_hits",
    "measure_misses", "layout_updates", "display_finalized", "full_passes",
    "global_fallbacks", "text_shapes", "nodes_created", "nodes_retired",
]

EXTENDED_FIELDS = [
    "retained_match", "structure_matches", "splice_count", "splice_elapsed_ns",
    "splice_tail_rejections", "layout_sparse_passes", "layout_suffix_skips",
    "layout_unchanged_skips", "stage_description_ns", "stage_reconcile_ns",
    "stage_reconcile_hash_ns", "stage_reconcile_copy_ns",
    "stage_structure_diff_ns", "stage_measure_ns", "stage_layout_ns",
    "stage_paint_ns", "stage_composition_ns", "stage_finalize_ns",
]


def parse_log(path, prefix):
    rows = {}
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if not line.startswith(prefix + " "):
                continue
            tokens = line.split()
            if len(tokens) < 4 or tokens[1] != "step":
                continue
            try:
                step = int(tokens[2])
            except ValueError:
                continue
            fields = {}
            for index in range(3, len(tokens) - 1, 2):
                fields[tokens[index]] = tokens[index + 1]
            rows[step] = {key: int(value) for key, value in fields.items()}
    return rows


def median(values):
    return statistics.median(values) if values else 0


def collect(directory, prefix, arm):
    per_step = {}
    files = [
        path for path in sorted(glob.glob(os.path.join(directory, "*.log")))
        if "warmup" not in os.path.basename(path)
        and os.path.basename(path).startswith(arm + "-")
    ]
    for path in files:
        rows = parse_log(path, prefix)
        for step, fields in rows.items():
            per_step.setdefault(step, []).append(fields)
    return per_step, len(files)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--prefix", default="alicorn-performance-sequence-counters")
    parser.add_argument("--baseline-log-dir", required=True)
    parser.add_argument("--candidate-log-dir", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    os.makedirs(args.out, exist_ok=True)
    baseline, baseline_files = collect(args.baseline_log_dir, args.prefix, "baseline")
    candidate, candidate_files = collect(args.candidate_log_dir, args.prefix, "candidate")
    steps = sorted(set(baseline) | set(candidate))

    with open(os.path.join(args.out, "counter-deltas.csv"), "w", newline="", encoding="utf-8") as handle:
        handle.write('"step","field","baseline_p50","candidate_p50"\n')
        for step in steps:
            for field in COMMON_FIELDS:
                base_values = [row[field] for row in baseline.get(step, []) if field in row]
                cand_values = [row[field] for row in candidate.get(step, []) if field in row]
                if not base_values and not cand_values:
                    continue
                handle.write(f'"{step}","{field}","{median(base_values)}","{median(cand_values)}"\n')

    with open(os.path.join(args.out, "candidate-extended-counters.csv"), "w", newline="", encoding="utf-8") as handle:
        handle.write('"step","field","candidate_p50"\n')
        for step in steps:
            for field in EXTENDED_FIELDS:
                values = [row[field] for row in candidate.get(step, []) if field in row]
                if not values:
                    continue
                handle.write(f'"{step}","{field}","{median(values)}"\n')

    # Compact per-step reuse table and aggregate.
    with open(os.path.join(args.out, "reuse-by-step.csv"), "w", newline="", encoding="utf-8") as handle:
        handle.write(
            '"step","emitted_p50","reused_p50","retained_match_p50","exact_match_share_of_emitted",'
            '"structure_matches_p50","reconcile_copy_ns_p50","reconcile_hash_ns_p50",'
            '"description_ns_p50","reconcile_ns_p50"\n'
        )
        for step in steps:
            cand = candidate.get(step, [])
            base = baseline.get(step, [])

            def cand_median(field):
                values = [row[field] for row in cand if field in row]
                return median(values) if values else ""

            def base_median(field):
                values = [row[field] for row in base if field in row]
                return median(values) if values else ""

            emitted = cand_median("emitted")
            matches = cand_median("retained_match")
            share = ""
            if emitted not in ("", 0) and matches != "":
                share = f"{100.0 * matches / emitted:.2f}"
            handle.write(
                f'"{step}","{emitted}","{cand_median("reused")}","{matches}","{share}",'
                f'"{cand_median("structure_matches")}","{cand_median("stage_reconcile_copy_ns")}",'
                f'"{cand_median("stage_reconcile_hash_ns")}","{cand_median("stage_description_ns")}",'
                f'"{cand_median("stage_reconcile_ns")}"\n'
            )

    emitted_total = sum(
        median([row["emitted"] for row in candidate.get(step, []) if "emitted" in row])
        for step in steps
    )
    match_total = sum(
        median([row["retained_match"] for row in candidate.get(step, []) if "retained_match" in row])
        for step in steps
    )
    copy_total = sum(
        median([row["stage_reconcile_copy_ns"] for row in candidate.get(step, []) if "stage_reconcile_copy_ns" in row])
        for step in steps
    )
    hash_total = sum(
        median([row["stage_reconcile_hash_ns"] for row in candidate.get(step, []) if "stage_reconcile_hash_ns" in row])
        for step in steps
    )
    print(f"{os.path.basename(os.path.normpath(args.out))}: {baseline_files} baseline logs, "
          f"{candidate_files} candidate logs, {len(steps)} steps")
    print(f"  candidate step-median totals: emitted {emitted_total}, retained_match {match_total} "
          f"({100.0 * match_total / emitted_total:.1f}%), reconcile_copy {copy_total} ns, "
          f"reconcile_hash {hash_total} ns")


if __name__ == "__main__":
    main()
