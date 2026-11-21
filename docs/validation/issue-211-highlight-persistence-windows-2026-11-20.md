# Issue #211 Stage D slice 2 - syntax highlighting lost while typing

Windows x64, NVIDIA GeForce RTX 2080 SUPER, 2026-11-20/21

Alicorn candidate: `codex/issue-211-scratchpad-webgpu` @ `1564110`
Scratchpad validator (read-only): `codex/issue-211-webgpu-frontend` @ `b458d6e`

## Symptom and scope

In the restored Go editor (`language/detection.go` shape, 42-line fixture), all
syntax highlighting disappeared as soon as a character was typed and did not
come back. The founder saw this on the hosted WebGPU build. The same input on
the SDL_GPU reference host reproduces it exactly, so this is not a hosted
renderer or wake-cadence defect: it is in the shared frontend's edit/publish
state machine. Alicorn's part of the chain (retained description -> presentation
list -> text mesh) carries whatever spans the application describes; it was
never given spans after the first keystroke.

Full capture data: [raw evidence][raw].

## The chain, step by step

1. **Scratchpad optimistic edit.** `editor_apply_local_replace_with_wire`
   (`frontends/alicorn/main.odin:2561`) calls `editor_window_replace_bytes`
   (`frontends/alicorn/editor_model.odin:906`), which clones the visible window,
   rebases every unaffected syntax record, sets `window.presentation_stale = true`
   and keeps `presentation_ready` from the base window (`editor_model.odin:970-982`).
   At this point the app can paint rebased tokens, and it does: the first
   post-edit frame still carries spans.
2. **Edit acknowledgement.** `editor_handle_edit_result`
   (`main.odin:3191`) drops `optimistic_pending_edits` to zero and advances only
   the optimistic window's `editor_revision` (`main.odin:3311-3313`). Its
   `presentation_revision` intentionally stays at the pre-edit revision and
   `presentation_stale` stays true until exact metadata arrives.
3. **Post-ACK description.** The backend has no derived projection for the new
   revision yet, so its `State_Document.presentation_ready` is false and the
   visible-window reply has no spans. The view-scoped installer
   (`application_install_view_visible_window`, `main.odin:750`) stores it as
   `view.source_window` (`main.odin:807`) but keeps the optimistic window.
4. **Asynchronous parser publication.** The language worker publishes exact
   projections for the accepted revision. The frontend requests a metadata
   refresh and receives a window with `presentation_ready=true`, the new
   `presentation_revision` and the exact spans; it is installed as
   `view.source_window`. Instrumentation shows this state clearly:
   `srcReady=true srcPR=2 srcSpans=102` while the optimistic window still reads
   `winStale=true winPR=0 winRev=2 spans=102`.
5. **Host wake and description.** Each publication wake and window completion
   invalidates the root and the next hosted/native description runs. This part
   works identically on both hosts; the captures below are rebuilt descriptions.
6. **Presentation selection.** `editor_presentation_window` (`main.odin:1704`)
   first calls `editor_view_window` (`editor_model.odin:830`). The optimistic
   branch at `editor_model.odin:836-843` returns the optimistic window whenever
   its `editor_revision` matches, which it now does. The exact `source_window`
   with published spans is never selected for painting.
7. **Text mesh invalidation.** Never reached with spans. `presentation_window_matches`
   (`app_editor_view.odin:513`) requires `!window.presentation_stale` and
   `window.presentation_revision == document.presentation_revision`; the stale
   optimistic window can never satisfy it. `metadata_refresh_needed` therefore
   stays true forever (`app_editor_view.odin:526`), and
   `app_editor_view.odin:753` forces `window_covers_view=false` while a refresh
   is pending. That makes `paint_current=false` (`app_editor_view.odin:915`), so
   `editor_presentation_spans_for_line` is not called (`:933-935`) for any row.
   The retained text nodes get span-less descriptions, and alicorn's inspector
   prints `paint-spans=0` for all of them.

The Go document's paint-only `DisplayCode` rebase cache
(`document/document.go:31-33`, `:766-799`) is real, but it is not part of the
frontend presentation protocol: no bridge or frontend call reads it. The
frontend's own rebase is what keeps the first post-edit frame highlighted; the
refresh gate then drops it.

## Evidence

Capture sequence: settle, F12, type the first character, F12 at +100 ms, finish
a six-character burst, F12 at +0.8 s, +3.3 s and +8.3 s. Counted from each
bundle's `inspector.txt`.

| leg | baseline | +100 ms | +0.8 s | +3.3 s | +8.3 s |
| --- | ---: | ---: | ---: | ---: | ---: |
| hosted WebGPU / D3D12 | 24 | 0 | 0 | 0 | 0 |
| SDL_GPU reference | 24 | 0 | 0 | 0 | 0 |

"24" is the number of text runs carrying at least one paint span in the settled
Go scene. Both hosts lose every span, including rows that were never edited.
The rows keep their text (the run byte counts grow with the typed characters),
so this is span publication, not text loss.

Screenshots (cropped editor band):

- [baseline](assets/issue-211-highlight-baseline.png)
- [hosted, after typing, before fix](assets/issue-211-highlight-hosted-before-fix.png)
- [SDL_GPU reference, after typing, before fix](assets/issue-211-highlight-reference-before-fix.png)
- [hosted, after typing, with the scratch-side candidate fix](assets/issue-211-highlight-hosted-after-fix.png)

The candidate fix was evaluated in a temporary copy of the validator checkout,
not in the validator worktree. In that copy,
`application_install_view_visible_window` drops the stale optimistic window when
it installs a `presentation_ready` source window with no pending edits. With
that one change the capture table becomes 24 spans in every phase on **both**
hosts, and the edited row keeps its tokens (`package`, strings, comments) while
the new text is present. This is a Scratchpad-side fix proposal; no Scratchpad
source or lock file was changed here.

## Alicorn-side regression cover

The hosted runtime was not the cause, but its half of the chain now has
edit-sequence coverage:

- `runtime/hosted_parity_test.odin`
  - `test_hosted_presentation_preserves_spans_across_an_edit_sequence` describes
    two highlighted rows, performs an optimistic value edit with rebased spans,
    then a later exact publication. It asserts rebased ranges and colors reach
    the hosted presentation list, the edited row gets a new text product, the
    untouched row keeps the same spans and the same text product, and the
    publication replaces rather than merges the rebased ranges.
- `renderer/webgpu/text_span_test.odin`
  - `test_webgpu_text_span_edit_sequence_reuses_only_identical_meshes` proves an
    identical description reuses the retained glyph mesh, a value+span edit
    invalidates it, and the settled edited description reuses the new mesh
    instead of rebuilding every frame.

## Validation

- `odin test runtime`: 420 tests pass (includes the new edit-sequence fixture).
- `odin test renderer/webgpu`: 9 tests pass (includes the new mesh fixture).
- Supporting suites on this branch: `host/presentation` 7, `renderer/cpu` 23,
  `theme` 37, `host/web` 14, `host/diagnostics` 9, `ui` 50, `testui` 13,
  `native/sdl_gpu` 168, `host/sdl3` 8, plus `odin build tests` and
  `out/alicorn_tests.exe` pass.
- Example 16 `--smoke` and `--workbench-smoke` pass on D3D12, Vulkan, and
  SDL_GPU (6/6).
- Scratchpad validator `b458d6e` smoke legs against this branch: hosted
  WebGPU/D3D12 and WebGPU/Vulkan pass (`publication_rendered`, `wake_observed`,
  `ordered_shutdown`, `session_restore` true for clean and recovery launches).
  The SDL_GPU leg passes the same checks; its first attempt timed out at 20 s
  because three leftover capture-probe windows from this investigation were
  still alive on the desktop, and it passed immediately after those were
  closed. No Scratchpad source or lock file changed.
- The same validator built and ran the typed capture sequence on both hosts;
  both reproduced the pre-fix failure and both recovered with the temporary
  candidate fix described below.

## Recommended Scratchpad follow-up

The smallest safe fix is at the point where an exact window is installed with no
pending edits (`main.odin:805-810`): retire `view.optimistic_window` (or copy the
exact `presentation_revision` and spans into it) so
`editor_presentation_window` / `editor_view_window` select the published window.
A second, defensive fix is to keep painting safe stale spans while
`metadata_refresh_needed` is true instead of forcing `window_covers_view=false`
at `app_editor_view.odin:753`. The first change alone restores continuous
highlighting in the validation above.

[raw]: raw/issue-211-highlight-edit-sequence-2026-11-20.txt
