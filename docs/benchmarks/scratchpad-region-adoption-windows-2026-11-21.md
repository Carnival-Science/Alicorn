# Matched Scratchpad adoption + three-arm Quick Open capture, Windows, 2026-11-21

Date: 2026-11-21

## Finding

This capture closes two loose ends of the issue #231 pilot: it **adopts** the
pilot's two least fragile keyed regions (document tab strip, sidebar workspace
tree) into a reviewable Scratchpad branch, and it **measures** the Quick Open
results slot with the missing query-typing scenario.

1. **Adoption is clean.** Branch `pilot/keyed-regions-tabstrip-tree` at
   `256628c` (5 files, +381/-3) reproduces the pilot's tab-strip and tree
   regions and their stale-output tests. The Scratchpad frontend suite is
   **259/259 green** and Alicorn's runtime suite is **497/497 green**. The
   nine-action smoke sequence passed in all 30 measured sequence processes.

2. **The typing burst reproduces the pilot's mechanism exactly.** Per
   character, emitted nodes fall **858 -> 741 (-13.6%)**, `regions_skipped`
   rises **0 -> 6**, and the runtime reconcile stage falls **0.832 -> 0.774 ms
   (-7.0%)**. Cumulative application build is **-4.4%** paired; two plain-arm
   startup stalls produce two extreme pairs (-63.5%/-84.2%), but the median is
   stable (the eight non-stall pairs give -4.1%). The application describe
   callback itself is flat, as in the pilot.

3. **The Quick Open results-slot region never skips while filtering.** Over
   **180/180** measured filter characters the region reports exactly **one**
   skip and **47** emitted descriptions, identical to the adopted arm without
   it. That one skip is the workspace tree; the results slot itself rebuilds
   every character because the query is a revision input. The per-keystroke
   node saving is **zero**. A small describe-window difference exists
   (median -7.9%), but it has no counter counterpart and is not claimed as a
   region effect.

4. **The command sequence still shows no reliable benefit.** Sequence build
   changes are dominated by a 800 ms adopted stall and by a 4-vs-5
   description-pass difference at close-README; steps outside Quick Open are a
   null control and move by up to -19.7%. No sequence claim is made.

Short answer: **GO for the tab strip and workspace tree on typing-style
workloads; NO-GO for the Quick Open results slot as a per-keystroke
optimization.** Its revision legitimately changes with every query character,
so it can only skip on a re-describe that does not change query, selection, or
scroll - a frame class this workload does not contain.

## Adoption record

| Item | Value |
| --- | --- |
| Base | Scratchpad `adb28fc220864e6809c9217e4437af5b92dae57b` (fresh clone) |
| Branch | `pilot/keyed-regions-tabstrip-tree` |
| Commit | `256628cc37c481b04c69c58dde21d38d960a89ff` |
| Patch | `raw/.../adoption-tabstrip-tree.patch`, SHA-256 `F63D6310...C891D73` |
| Files | 5 (3 modified, 2 added) |
| Lines | +381 / -3 |
| Frontend suite | 259/259 green (`raw/.../logs/frontend-test.log`) |
| Alicorn runtime suite | 497/497 green (`raw/.../logs/alicorn-runtime-test.log`) |
| Push | `origin` (clone's local source checkout) and `https://github.com/samanshaiza004/scratchpad.git` both accepted the branch |

Per-site cost matches the pilot's burden record:

| Site | Region key | Lines | Revision source |
| --- | --- | ---: | --- |
| Document tab strip (compact titlebar) | `scratchpad-doc-tabs` | 135 | monotonic generation over prepared tab items, drag/find/theme/search/accessibility state, retained tab-bar viewport, polled interaction |
| Sidebar workspace tree | `scratchpad-workspace-tree` | 68 | monotonic generation over projection revision, realized scroll window, AliKit focus/selection revision, session restore, theme/accessibility |
| Revision helper | - | 67 | `Region_Generation`, `region_generation_next`, hash helpers |
| Guard tests | - | 101 | monotonic-generation test + stale-output guard |
| App state | - | 10 | two generations + hoisted connected-tab node cache |

### What was deliberately not adopted

- The **pinned surface** region (unexercised by either scenario and the
  pilot's most fragile site).
- The **Quick Open results slot** region (arm C only; measured here).
- **No `invalidate_region` conversions.** The pilot converted exactly
  `quick_open_text_change` and `quick_open_move_selection`, and both feed only
  the Quick Open slot. The adopted tab strip and tree rebuild through their
  revision signatures on the ordinary root-invalidation path; there is no
  converted site that feeds only them.

### Harness provenance

All three arms carry the same environment-gated harness (`adoption-harness.patch`,
SHA-256 `FCBBAE08...76F9C2`). It embeds the phase-2 typing hook
(`scratchpad-perf-typing-hook.patch`, SHA-256 `8640D486...B4ED86`) unchanged
and adds the new **`SCRATCHPAD_ALICORN_PERF_QUICKOPEN`** filter burst. The
nine-action sequence and 24-character editor burst are the reused hooks; the
third phase opens Quick Open, waits for the path index and query focus, commits
**19** characters of `application/sample_` one at a time with
`alicorn.process_text_input`, dispatches each `Text_Change` through the
application's normal `command_palette_text_change` path, and closes the
surface in a separately attributed tail. No native key or pointer events are
synthesized.

The sequence-only per-step counters use a separate diagnostic variant
(`sequence-counters-diagnostic.patch`, SHA-256 `BC048AE4...2E170A`) built into
`out/diag` binaries; its timings are not used for any timing claim.

## Revisions and environment

| Item | Value |
| --- | --- |
| Alicorn | `bd81fe5b0eaef1996e241f22a23b712823c11926` (same for all three arms) |
| Scratchpad plain | `adb28fc...` + harness |
| Scratchpad adopted | `256628c...` + harness |
| Scratchpad quickopen | `256628c...` + quickopen-results patch + harness |
| Caliber | `197cd964cc7265bc60df599a6b8562eac7c75f3a` |
| Host | Windows 10 Home 22H2, build 19045; Ryzen 5 7600X, 12 logical processors; 15 GiB RAM |
| GPU | NVIDIA GeForce RTX 2080 SUPER, driver 32.0.15.9597 |
| Native backend | SDL_GPU reference host / Direct3D 12 |
| Toolchain | Odin `dev-2026-11-nightly:08539cd`; Go `go1.27.1` |
| Build profile | Release, Odin `-o:speed`; `--release` passed explicitly |
| Display | Scale 1.0; logical size equals pixel size |
| Theme | Scratchpad default Warm theme; no saved preference |

Binaries (A/B builds, SHA-256): plain
`943BBA26...F953D8E0`, adopted `F718CBDC...F398820`, quickopen
`654B079F...8952B86`. Each build's `artifact-manifest.json` pins Alicorn
`bd81fe5` and Caliber `197cd96` (`logs/artifact-manifest-*.json`).

## Workload and method

### Fixture

The 2026-11-04/2026-11-21 fixture: eight directories, 192 small files, a
README, and a 5,002-line `application/sample_00.go` (193 files). Every process
gets a fresh `APPDATA`/`LOCALAPPDATA` profile and the same workspace path.

### Three scenarios, one per process

The reference host exits smoke at its fixed 3 s window after startup, so the
three phases run as separate processes, each with the same binary:

1. **Sequence** - nine actions: open `README.md`; open the Go document; switch
   back; open Quick Open; close it once the index is ready; open Settings;
   close Settings; close README; close the remaining document.
2. **Typing** - open the Go document (setup, unmeasured), then 24 committed
   single-character insertions through `editor_text_input`, one measured step
   per character.
3. **Quick Open filter** - open Quick Open and wait for the index and query
   focus (setup, unmeasured), then 19 committed query characters through
   `process_text_input` + `command_palette_text_change`, one measured step per
   character; close in a measured tail.

Cadence: first action 500 ms after start; each later step advances only after
the previous step's description was built, with a 30 ms floor.

### Protocol

- **10 matched pairs per scenario** (7 primary + 3 confirmation), three arms
  per round, balanced six-order rotation.
- One unmeasured warmup per arm per scenario.
- Every measured sample must pass smoke and its scenario acceptance; an
  acceptance failure is retried up to three times with the failed log kept.
  One typing sample (quickopen arm, primary run-03) needed two attempts; all
  90 measured samples and 9 warmups passed.
- The task asked for 5+2 pairs. The capture keeps the precedent's 7+3 because
  the first seven pairs showed stall-driven pair spread above 25% in every
  scenario, and adds no further exclusion: **all samples are reported**.
- Percentiles are nearest-rank p50/p95, as in prior captures.

### Metrics

- **Cumulative app build:** host sum of application build callbacks.
- **Describe window (`scenario_build_ns`):** sum of measured application
  describe callbacks; excludes `end_frame`.
- **Per step/character:** action time, describe window, build count, emitted,
  reused, `regions_skipped`, retained reuse; per-character counters exist for
  typing and Quick Open (the sequence uses the diagnostic variant).
- **Paired change:** nearest-rank median of per-pair percentage changes, second
  arm relative to first; positive is slower.

## Results

Times in ms unless noted. `A` = plain, `B` = adopted, `C` = adopted + Quick
Open results region.

### Process metrics, ten pairs per scenario

| Scenario | Metric | A p50 (p95) | B p50 (p95) | C p50 (p95) | A->B paired | B->C paired | A->C paired |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Sequence | Cumulative app build | 32.018 (33.87) | 32.127 (37.45) | 30.331 (32.28) | -2.07% | -6.48% | -7.81% |
| Sequence | Largest app build | 8.847 (11.83) | 9.384 (11.25) | 8.225 (9.41) | -3.4% | -19.9% | -10.3% |
| Sequence | Sequence build | 19.340 (20.92) | 19.079 (23.97) | 17.927 (19.72) | -1.96% | -10.56% | - |
| Sequence | First submission | 16.485 (17.36) | 16.772 (17.59) | 17.271 (109.23) | -2.9% | +3.0% | -0.5% |
| Sequence | Process CPU | 765.6 (828.1) | 796.9 (875.0) | 781.3 (859.4) | +6.7% | -2.0% | -2.3% |
| Sequence | Process wall | 5,293.9 (6,163.0) | 4,929.9 (5,592.8) | 4,763.2 (6,172.9) | -2.6% | +0.6% | -0.7% |
| Sequence | Peak working set MiB | 325.42 (328.90) | 324.81 (325.16) | 325.05 (326.99) | -0.6% | +0.1% | -0.5% |
| Typing | Cumulative app build | 58.849 (154.40) | 56.367 (58.06) | 56.096 (61.14) | **-4.41%** | -1.46% | -6.44% |
| Typing | Largest app build | 7.997 (93.80) | 7.894 (8.67) | 8.153 (11.36) | -1.8% | +0.1% | -4.9% |
| Typing | Typing build | 18.990 (111.66) | 18.479 (19.74) | 18.448 (19.78) | -2.69% | +0.58% | - |
| Typing | First submission | 10.783 (17.17) | 10.328 (17.34) | 10.969 (106.79) | -4.6% | +5.5% | +1.7% |
| Typing | Process CPU | 1,875.0 (2,031.3) | 2,000.0 (2,062.5) | 2,031.3 (2,218.8) | +1.7% | 0.0% | +6.7% |
| Typing | Process wall | 5,031.3 (7,088.7) | 5,525.0 (7,423.7) | 5,073.5 (6,646.3) | -3.6% | -10.4% | -0.9% |
| Typing | Peak working set MiB | 339.07 (340.53) | 339.85 (340.34) | 340.20 (341.84) | +0.2% | +0.2% | +0.3% |
| Quick Open | Cumulative app build | 7.416 (7.73) | 6.777 (6.98) | 6.681 (6.96) | **-8.66%** | -2.40% | -10.95% |
| Quick Open | Largest app build | 1.560 (1.81) | 1.649 (2.00) | 1.632 (1.92) | +2.0% | -2.0% | +3.5% |
| Quick Open | Filter burst build | 1.990 (2.12) | 1.802 (1.90) | 1.675 (1.78) | **-10.51%** | -7.92% | -17.0% |
| Quick Open | First submission | 17.245 (707.09) | 16.090 (75.59) | 16.867 (18.37) | -9.7% | +4.8% | -11.2% |
| Quick Open | Process CPU | 468.8 (515.6) | 421.9 (500.0) | 453.1 (546.9) | -9.1% | +7.4% | 0.0% |
| Quick Open | Process wall | 6,670.8 (8,112.4) | 5,843.4 (6,538.5) | 5,622.5 (6,540.3) | -15.4% | -3.8% | -15.9% |
| Quick Open | Peak working set MiB | 290.77 (304.22) | 290.71 (291.38) | 290.85 (291.27) | -0.1% | -0.1% | -0.1% |

Paired application-build changes:

- Typing A->B: `-3.1, -63.5, -7.0, -0.7, -4.1, +7.0, -7.9, -84.2, -4.4, -1.8`
  (eight negative; the two large negatives are plain-arm startup stalls).
- Quick Open A->B: `-13.8, -8.7, -6.6, -3.6, +5.6, -12.5, -98.8, -5.3, -10.2, -7.7`
  (nine negative; the -98.8 pair contains a 557 ms plain stall).
- Quick Open B->C: `+4.4, -2.5, -11.1, -1.4, -16.5, +7.2, -1.4, -2.4, -4.8, +10.1`
  (mixed sign; median -2.40%).
- Sequence A->B: `+11.7, -7.9, -0.6, -10.4, +6.2, -2.1, -3.8, -14.0, +6.6, +2415.5`
  (one 800 ms adopted stall dominates the mean; median still -2.07%).
- Sequence B->C: `-22.3, +0.1, -11.6, -1.4, -12.4, +2.1, +2.7, +2.3, -6.5, -96.0`
  (the -96 pair is the same stall measured against the quickopen arm).

### Sequence steps, ten pairs

| Step | A build | B build | C build | A->B | B->C | builds A/B/C |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 0. Open README | 0.558 | 0.514 | 0.519 | -5.5% | -1.4% | 3/3/3 |
| 1. Open Go document | 7.576 | 7.286 | 6.878 | -4.5% | -19.7% | 5/5/5 |
| 2. Switch to README | 0.332 | 0.315 | 0.313 | -9.3% | -4.1% | 3/3/3 |
| 3. Open Quick Open | 0.228 | 0.209 | 0.206 | -10.1% | -3.6% | 2/2/2 |
| 4. Close Quick Open | 0.552 | 0.508 | 0.537 | -15.5% | +12.0% | 4/4/4 |
| 5. Open Settings | 0.918 | 0.997 | 0.894 | +1.7% | -13.8% | 2/2/2 |
| 6. Close Settings | 0.113 | 0.085 | 0.099 | -19.4% | +8.1% | 1/1/1 |
| 7. Close README | 8.039 | 8.506 | 8.182 | +2.3% | -3.8% | 5/5/**4** |
| 8. Close Go document | 0.122 | 0.113 | 0.114 | -7.3% | +13.9% | 1/1/1 |

Step 1's -19.7% B->C is outside Quick Open and is a **null-control
divergence**: C differs from B only in `quick_open.odin`, so a 7.3 ms build
moving by 0.4 ms between builds is code-layout/pass noise, not a region effect.
Step 7 confirms the sensitivity: C runs four description passes where A and B
run five, so its build is not comparable.

### Sequence per-step counters (diagnostic, 3 runs per arm)

Medians per step. `emitted/skipped`; the quickopen arm is identical to adopted
on skips in every step.

| Step | A emitted | A skip | B emitted | B skip | C emitted | C skip |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 278 | 0 | 213 | 3 | 213 | 3 |
| 1 | 938 | 0 | 790 | 6 | 790 | 6 |
| 2 | 342 | 0 | 250 | 4 | 250 | 4 |
| 3 | 244 | 0 | 199 | 2 | 199 | 2 |
| 4 | 115 | 0 | 320 | 6 | 320 | 6 |
| 5 | 286 | 0 | 241 | 2 | 241 | 2 |
| 6 | 115 | 0 | 68 | 2 | 185 | 2 |
| 7 | 1,274 | 0 | 1,131 | 7 | 1,131 | 7 |
| 8 | 56 | 0 | 57 | 0 | 57 | 0 |

The adopted arm skips the tab strip and tree on every step that describes
them. The Quick Open arm adds **no** skip: at step 3 the results region is
first described (cannot skip), at step 4 it no longer exists, and on the
intervening frames the query/selection are unchanged only when the whole
surface is not being described. Step 6's C emitted count (185 vs 68) is a
diagnostic-run pass-count difference, not a region effect; skip counts are
identical.

### Typing burst, per character

Counters are medians over characters 1..23 of each run, then across ten runs.

| Counter | Plain | Adopted | Change |
| --- | ---: | ---: | ---: |
| Emitted | 858 | **741** | **-13.6%** |
| Reused | 855 | 738 | - |
| `regions_skipped` | 0 | **6** | - |
| Retained subtree reuse | 0 | 6 | - |
| Layout visits | 94 | 94 | 0 |
| Text shapes | 2 | 2 | 0 |
| Runtime description stage | 1.564 ms | 1.556 ms | -0.5% |
| Reconcile stage | 0.832 ms | **0.774 ms** | **-7.0%** |

Six skips per character = tab strip and tree, three description passes each.
This is the pilot's counter result reproduced exactly (pilot: 858 -> 741, 0 ->
6, reconcile -13.7% with a different editor mix).

Per-character describe windows (µs; arm median over ten runs, paired percentages
median over ten pairs):

| Step | A | B | C | A->B | A->C |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 676.3 | 664.2 | 645.1 | -7.4% | -9.3% |
| 2 | 719.2 | 736.4 | 672.1 | +2.4% | -9.9% |
| 3 | 745.1 | 758.5 | 765.6 | -7.0% | -8.4% |
| 4 | 819.2 | 852.7 | 831.4 | +11.7% | +5.2% |
| 5 | 694.7 | 774.5 | 711.8 | +10.5% | -3.4% |
| 6 | 688.5 | 670.4 | 683.0 | -2.6% | -5.7% |
| 7 | 650.4 | 631.7 | 683.8 | -7.5% | +2.5% |
| 8 | 757.0 | 811.9 | 676.2 | +0.3% | -12.9% |
| 9 | 852.7 | 844.8 | 824.9 | -7.1% | +2.7% |
| 10 | 857.5 | 813.9 | 743.2 | -1.9% | -18.4% |
| 11 | 811.0 | 879.2 | 744.3 | -8.9% | -9.1% |
| 12 | 741.8 | 762.5 | 718.5 | -8.5% | +2.9% |
| 13 | 791.1 | 728.1 | 754.1 | +0.8% | -0.8% |
| 14 | 814.7 | 754.2 | 861.7 | -13.1% | -0.6% |
| 15 | 828.7 | 860.5 | 803.1 | +3.3% | -2.2% |
| 16 | 722.5 | 754.7 | 934.7 | -3.5% | +9.8% |
| 17 | 703.3 | 754.5 | 709.0 | +8.7% | +4.0% |
| 18 | 645.6 | 742.6 | 752.2 | +4.2% | +5.0% |
| 19 | 699.4 | 693.1 | 817.8 | +4.8% | +21.1% |
| 20 | 799.6 | 803.5 | 731.2 | -3.0% | -10.6% |
| 21 | 766.7 | 727.7 | 759.3 | -5.6% | +12.3% |
| 22 | 818.5 | 665.2 | 749.2 | -18.7% | -7.3% |
| 23 | 675.4 | 756.6 | 679.5 | +5.5% | -8.6% |

Step 0 is excluded as settle-affected (first character after focus). The
per-step series is noisier than the counter series; the region mechanism is
established by emitted/skipped and stage totals, not by any single step. The C
column is a **null control** for the editor burst (Quick Open is closed): its
paired median is -1.46% with mixed signs, i.e. noise, as expected.

The complete 24-step samples are in `typing/combined/steps.csv`; the medians
and pair changes are in `typing/combined/combined.json`.

### Quick Open filter burst, per character

All 18 measured characters of `application/sample_`; the query field is
outside the region, so the results slot's revision changes on every step.

| Char | A build µs | B build µs | C build µs | B->C | A->C | A emitted | B emitted | C emitted | B skip | C skip | C results |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 88.4 | 84.7 | 87.2 | -2.1% | -14.4% | 76 | 47 | 47 | 1 | 1 | 192 |
| 2 | 100.3 | 85.2 | 78.5 | -3.0% | -20.4% | 76 | 47 | 47 | 1 | 1 | 24 |
| 3 | 99.3 | 84.8 | 90.4 | -9.9% | -7.0% | 76 | 47 | 47 | 1 | 1 | 24 |
| 4 | 98.6 | 84.1 | 88.2 | +3.0% | -6.4% | 76 | 47 | 47 | 1 | 1 | 24 |
| 5 | 98.5 | 91.0 | 77.6 | -8.3% | -14.8% | 76 | 47 | 47 | 1 | 1 | 24 |
| 6 | 96.5 | 90.0 | 83.1 | -14.1% | -14.3% | 76 | 47 | 47 | 1 | 1 | 24 |
| 7 | 103.3 | 84.4 | 72.7 | -20.4% | -30.4% | 76 | 47 | 47 | 1 | 1 | 24 |
| 8 | 97.1 | 78.8 | 80.8 | -18.7% | -11.4% | 76 | 47 | 47 | 1 | 1 | 24 |
| 9 | 98.5 | 88.0 | 84.2 | -4.3% | -15.8% | 76 | 47 | 47 | 1 | 1 | 24 |
| 10 | 99.1 | 89.1 | 86.8 | -3.3% | -19.7% | 76 | 47 | 47 | 1 | 1 | 24 |
| 11 | 100.7 | 91.6 | 82.4 | -11.9% | -14.4% | 76 | 47 | 47 | 1 | 1 | 24 |
| 12 | 97.5 | 91.3 | 84.9 | -6.4% | -15.1% | 76 | 47 | 47 | 1 | 1 | 24 |
| 13 | 97.1 | 91.7 | 87.2 | -3.6% | -26.0% | 76 | 47 | 47 | 1 | 1 | 24 |
| 14 | 98.2 | 95.1 | 85.0 | -9.0% | -15.8% | 76 | 47 | 47 | 1 | 1 | 24 |
| 15 | 95.1 | 93.1 | 85.4 | -12.9% | -23.4% | 76 | 47 | 47 | 1 | 1 | 24 |
| 16 | 104.1 | 90.8 | 89.1 | -0.5% | -11.9% | 76 | 47 | 47 | 1 | 1 | 24 |
| 17 | 104.5 | 92.1 | 84.1 | -10.7% | -19.6% | 76 | 47 | 47 | 1 | 1 | 24 |
| 18 | 108.4 | 96.0 | 87.4 | -4.0% | -13.4% | 76 | 47 | 47 | 1 | 1 | 24 |

| Metric | Plain | Adopted | Quickopen |
| --- | ---: | ---: | ---: |
| Median character describe window | 98.5 µs | 90.0 µs | 84.9 µs |
| Filter burst total (19 chars) | 1.990 ms | 1.802 ms | 1.675 ms |
| Setup (open + index + focus) | 149.7 µs | 180.7 µs | 179.5 µs |
| Tail (close) | 76.4 µs | 67.8 µs | 60.4 µs |
| Emitted per character | 76 | 47 | 47 |
| `regions_skipped` per character | 0 | 1 | 1 |

**The results region never skipped.** Across 180 measured filter-character
samples (10 runs x 18 characters) arm C reports `regions_skipped=1` and
`emitted=47` every time, exactly the adopted arm's values. That one skip is
the workspace tree (no document is open in this scenario, so the tab strip has
no region to build). The results slot rebuilds every character because
`quick_open_query` is in its revision - which is required for correctness.
Arm C's result counts track arm B exactly (193 -> 192 -> 24), so the region is
functionally correct, just never reusable during typing.

The C-vs-B describe-window difference (~5 µs/char) has **no** emitted or skip
counterpart and is within cross-build code-layout noise (the null-control
typing burst B-vs-C is -1.46% with mixed signs). It is not reported as a
region benefit.

### Adoption benefit check on the editor burst

The pilot attributed its -6.2% typing gain to the tab strip and tree; its
Quick Open and pinned regions are inactive during that burst (the pilot says
so). The correct reproduction target is therefore the pilot's -6.2%, not a
smaller number. This capture measures:

- **-4.41%** cumulative app build (median of ten pairs; two plain-arm stalls
  make two extreme pairs, and the remaining eight pairs give -4.1%);
- **-2.69%** describe-window total, flat application callback per character;
- **-13.6%** emitted nodes, **+6 skips/char**, **-7.0%** reconcile stage.

The counters reproduce the pilot exactly; the timing point estimate is 1.8
points weaker than the pilot and within this host's stall noise. Directionally
consistent, no regression, but not a stronger claim than "a few percent."

## Interpretation

- **Why typing improves:** the editor's caret/row work is unchanged, but the
  tab strip and tree bodies are skipped on all three description passes per
  character. That removes 117 of 858 described nodes per character and 7% of
  the reconcile stage; the application callback stays flat because the editor
  describe and text shaping dominate it.
- **Why the Quick Open region does not help typing:** its inputs include the
  query. Every committed character changes the query and therefore the result
  rows, so the revision must advance. A region that cannot skip is just a
  container. It could only pay on a re-describe with unchanged query,
  selection, index, and scroll (for example hover/paint invalidation or a
  repeated settle pass), which this workload does not produce.
- **Why the command sequence is not evidence:** the sequence changes documents,
  layout, and the described surfaces; the tab strip and tree themselves change,
  so they rebuild. The one large step (document open) is noisy across builds,
  and the close-README pass count varies with settle timing. B-vs-C step
  differences outside Quick Open are a null control proving this noise floor.
- **Relation to phase 2:** the same composition as the pilot. Phase 2 skips the
  reconcile copy for byte-identical re-emits; the adopted regions remove
  emit work before phase 2 sees it. In the typing burst 738 of 741 emitted
  nodes are exact matches, so phase 2 still skips almost all of the smaller
  description.

## Verdict (issue #231 GO/NO-GO framing)

- **GO - adopt tab strip + workspace tree.** They are deterministic
  projections with enumerable inputs, pass the stale-output guard, reproduce
  the pilot's node/reconcile savings exactly, and cost 213 product lines
  (203 of region code plus 10 state fields) and 168 lines of helper and tests for two sites. Push the branch for
  review; do not broaden to other surfaces without the same per-site revision
  audit.
- **NO-GO - Quick Open results slot as a per-keystroke optimization.** It
  never skipped in 180/180 filter characters and emitted exactly the same node
  count as the arm without it. Keep it only if a separate measurement shows a
  meaningful non-typing re-describe path (open/close is a single first
  describe; selection moves change the revision by design).
- **NO-GO - broad conversion.** The remaining ~350 `invalidate_root` sites
  have no per-region measurement; the sequence continues to show no reliable
  gain.
- **Not decided here:** pinned surface (still unmeasured and the most fragile
  site).

## Limitations

- The hooks invoke application/backend command paths and committed text
  changes on a schedule; they are not native input and do not measure input
  latency.
- Startup stalls occurred in every scenario (154-800 ms; one 557 ms plain Quick
  Open process, 367/154 ms plain typing processes, 800 ms adopted sequence
  process). They are retained; p95 is inflated and medians are the headline.
- The 3 s smoke window includes startup. Cold first submissions up to 1.3 s can
  consume it; one sample was retried (failed log kept). A retry only affects
  whether a run is accepted, not the measured workload, but it is a selection
  on process health.
- The Quick Open burst types an ASCII path query; it does not exercise IME,
  selection moves, scrolling, or result activation.
- Sequence counters come from separate diagnostic binaries; their timings are
  not used.
- One host, one Odin build, display scale 1.0, SDL_GPU reference host; do not
  compare numbers across machines.
- Region revisions remain application-declared; tests cover stale-output
  detectability, not full input completeness for future edits.
- The C arm's per-character describe-window difference has no counter
  explanation; treat it as noise, not a result.

## Reproduction artifacts

- [Capture manifest and SHA-256 pins](raw/scratchpad-region-adoption-windows-2026-11-21/manifest.json)
- [Three-arm runner](raw/scratchpad-region-adoption-windows-2026-11-21/run_windows_adoption.ps1)
  and [combination script](raw/scratchpad-region-adoption-windows-2026-11-21/analyze_adoption.py)
- [Adopted diff](raw/scratchpad-region-adoption-windows-2026-11-21/adoption-tabstrip-tree.patch)
- [Benchmark harness (reused hooks + new Quick Open burst)](raw/scratchpad-region-adoption-windows-2026-11-21/adoption-harness.patch)
- [Quick Open results-region patch (arm C)](raw/scratchpad-region-adoption-windows-2026-11-21/quickopen-results.patch)
- [Sequence counter diagnostic patch](raw/scratchpad-region-adoption-windows-2026-11-21/sequence-counters-diagnostic.patch)
- Sequence CSVs: [primary](raw/scratchpad-region-adoption-windows-2026-11-21/sequence/),
  [confirmation](raw/scratchpad-region-adoption-windows-2026-11-21/sequence-confirmation/),
  [combined](raw/scratchpad-region-adoption-windows-2026-11-21/sequence/combined/)
- Typing CSVs: [primary](raw/scratchpad-region-adoption-windows-2026-11-21/typing/),
  [confirmation](raw/scratchpad-region-adoption-windows-2026-11-21/typing-confirmation/),
  [combined](raw/scratchpad-region-adoption-windows-2026-11-21/typing/combined/)
- Quick Open CSVs: [primary](raw/scratchpad-region-adoption-windows-2026-11-21/quickopen/),
  [confirmation](raw/scratchpad-region-adoption-windows-2026-11-21/quickopen-confirmation/),
  [combined](raw/scratchpad-region-adoption-windows-2026-11-21/quickopen/combined/)
- [Sequence per-step counters](raw/scratchpad-region-adoption-windows-2026-11-21/diagnostics/sequence/)
- [Process logs](raw/scratchpad-region-adoption-windows-2026-11-21/typing/logs/) are
  in each scenario's `logs/` directory; build/test logs and artifact manifests
  are in [`logs/`](raw/scratchpad-region-adoption-windows-2026-11-21/logs/)
