# Issue #197: application-owned configurable command bindings

Date: 2026-11-21
Platform: Windows 11, real GPU and native Win32 menu bar
Branch: `codex/issue-197-command-bindings`

## Scope

This record verifies the opt-in binding surface added for issue #197:

- one host-neutral `Key_Event` produced by native SDL and headless `testui`;
- application-owned `Binding_Table`/`Command_Binding` values identified by
  `Action_ID`, with no new command enum;
- a host-owned chord resolver with scheduled-wake timeout and explicit
  cancellation;
- native menu accelerator refresh and rebuild after a runtime remap;
- `ui.run` / `ui/webgpu.run` / browser `run` exposure through optional
  `bindings` and `on_command`.

The ordinary path remains the default: an empty table creates no resolver state,
arms no wake, and leaves the existing menu, `Application_Key`, interaction
scope, text, and focused-control routing in place.

## Event contract

`alicorn.Key_Event` is the single keyboard contract. It carries a diagnostic
`scancode`, host-neutral `Key_Spec`, normalized `Key_Modifiers` (shared with
native menus, so `Primary` is Ctrl on Windows/Linux and Command on macOS),
repeat, composition and text-focus context, `produces_text`, a monotonic
timestamp, and an optional `application_key` bridge for the legacy enum.

Native normalization lives in `host/sdl3/input` (`key_event_from_sdl`); the
browser host maps DOM `KeyboardEvent.code` into the same struct; `testui`
constructs the same struct from synthetic turns. `hosted_runtime_key_event` is
the canonical hosted entry point. The legacy
`hosted_runtime_application_key` shim now forwards through it with
`Key_Spec.Unknown`, preserving hosts that only supply `Application_Key`.

## Ordering decision

Native key-down order is:

1. transient Select/context-menu overlays;
2. native menu-mode keys and menu accelerators;
3. host diagnostics (reference SDL_GPU host only);
4. application binding resolver;
5. the existing `Application_Key` / interaction-scope / focused-control / text
   path.

The resolver is additive. Unmatched keys fall through unchanged; a consumed
binding returns before the legacy path. `testui` applies the same order minus
native menus: typed-input overlays, bindings, then the existing routing.

## Chord semantics

- A single-stroke binding fires immediately when no longer binding shares the
  prefix.
- A shared prefix arms pending state and a Frequent-class deadline; the host
  sleeps until `next_wake`/its event wait timeout rather than polling.
- A later stroke completes a binding, or cancels and reprocesses itself as a
  fresh first stroke.
- At the deadline an exact complete binding fires (shorter exact match wins);
  otherwise pending state cancels.
- Composition cancels pending state and suppresses bindings that do not set
  `allow_during_composition`. Focused text or expected text requires
  `preempt_text`. Focus loss, committed/preedit/canceled text, pointer-down, and
  service cancel clear pending state.
- `binding_conflicts` reports `Duplicate_Stroke`, `Prefix_Ambiguity`, and
  `Scope_Overlap` in stable table order.

## Acceptance evidence

| Acceptance item | Evidence |
| --- | --- |
| Runtime remap keeps menu accelerator and dispatch synchronized | `host/menus` Windows test mutates a borrowed shortcut, verifies `Ctrl+S` -> `Ctrl+Shift+J` in the live `HMENU` label through `native_menu_adapter_refresh_accelerators`, verifies `menu_service_match_shortcut` follows the same storage, rebuilds a two-menu structure, then defers a three-menu rebuild while `WM_ENTERMENULOOP` is active and drains it on `WM_EXITMENULOOP`. `host/bindings` and `testui` tests remap the table and show old strokes stop resolving while new ones dispatch. |
| A command outside Alicorn's enum can be bound | `runtime`, `host/bindings`, and `testui` tests bind `Action_ID(9001)` and similar values. No `Application_Key` case was added. |
| Deterministic, cancellable multi-stroke chords return to idle | `runtime/bindings_test.odin` covers completion, shorter-exact timeout, incomplete-timeout cancel, unmatched reprocessing, composition cancel, and stale epoch. `host/bindings` covers scheduled-wake arming/completion and timeout. `testui` covers pending with zero idle descriptions, completion, virtual-clock timeout, unmatched/pointer cancel, and backend idle afterwards. |
| Native and synthetic input share one contract | `runtime/key_event_test.odin` asserts the value contract; `host/sdl3/input` tests assert SDL normalization; `testui` drives the same `Binding_State`/`Key_Event` shape. `hosted_runtime_key_event` is the canonical hosted path with the legacy shim test. |
| Ordinary `ui.run` remains small/unchanged | `ui.run` gains two optional parameters defaulting to an empty table/nil callback. The hosted resolver is skipped when the table is empty (`test_hosted_application_key_shim_preserves_opaque_event_and_ordinary_path` checks no deadline is armed). Existing interaction-scope, text-preemption, roving, input-mapping, menu, and hosted key-contract suites pass. |

## Platform limits

- Windows: native menu refresh, deferred rebuild, and dispatch were exercised
  against a live hidden SDL window and real Win32 menu handles.
- macOS: the Darwin adapter implements targeted `setTitle`/`setKeyEquivalent`
  and modifier-mask refresh plus rebuild through the shared adapter API. This
  branch was compile-checked from Windows; no macOS runtime execution was done.
- Linux: native menus remain semantic accelerator metadata only, matching the
  existing adapter. `native_menu_adapter_refresh_accelerators` is a documented
  no-op.
- Browser: the DOM `KeyboardEvent.code` mapping and canonical hosted key path
  compile in the web host and its tests; no interactive browser menu
  integration exists (browser menus remain out of scope).

## Suites

Windows results from this branch:

| Suite | Result |
| --- | --- |
| `runtime` | 511 tests passed (includes the new key-event, binding, and hosted-binding tests) |
| `host/bindings` | 5 tests passed |
| `host/sdl3` | 8 tests passed |
| `host/sdl3/input` | 10 tests passed (includes SDL `Key_Event` normalization) |
| `host/menus` | 10 tests passed (real hidden SDL window and Win32 menu handles) |
| `host/web` | 14 tests passed |
| `testui` | 37 tests passed (with the AccessKit collection flags used by the other hosted suites) |
| `ui` | 57 tests passed |
| `theme` | passed |
| `native/sdl_gpu` | 172 tests passed |
| `renderer/cpu` | passed |
| foundation (`out/alicorn_tests.exe`) | passed |
| restoration, native text-input contract, theme CLI/codegen | passed |

Two harness steps in `tools/test.ps1` fail identically on the untouched master
checkout in this environment, before any #197 code is compiled:

- `tools/check_web_ui_package.ps1` fails on `core:os is unsupported on js/wasm`
  with the installed Odin toolchain;
- the unqualified `odin test testui` invocation needs the AccessKit collection
  flags that the other hosted suites already receive, otherwise its existing
  `host/sdl3/accessibility` test imports fail.

The #197 testui suite passes with those collection flags. Darwin cross-check:
`odin check host/menus -target:darwin_amd64 -no-entry-point` passes; a full
`host/sdl3` Darwin check is blocked locally by the missing macOS wgpu-native
archive.

Full-suite output is recorded in the session log for this branch.
