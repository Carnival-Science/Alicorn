#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)
OUT_DIR=$REPO_ROOT/out

. "$SCRIPT_DIR/common.sh"
ODIN_ARG=
if [ "${1-}" = '--odin' ]; then
    if [ "$#" -lt 2 ]; then
        echo "Usage: $0 [--odin PATH]" >&2
        exit 2
    fi
    ODIN_ARG=$2
    shift 2
fi
if [ "$#" -ne 0 ]; then
    echo "Usage: $0 [--odin PATH]" >&2
    exit 2
fi
ODIN=$(alicorn_resolve_odin "$ODIN_ARG")

cd "$REPO_ROOT"
mkdir -p "$OUT_DIR"
ACCESSKIT_LINK_FLAGS=$(alicorn_accesskit_linker_flags)
ACCESSKIT_BINDING_ROOT=$(alicorn_accesskit_binding_root)
sh "$ACCESSKIT_BINDING_ROOT/tools/check.sh" --odin "$ODIN" --cache-root "$REPO_ROOT/.deps/accesskit"

"$ODIN" build tests "-out:$OUT_DIR/alicorn_tests"
"$OUT_DIR/alicorn_tests"
alicorn_odin_with_linker_flags "$ODIN" "$ACCESSKIT_LINK_FLAGS" \
	build native/sdl_gpu_entry "-collection:alicorn=$REPO_ROOT" "-out:$OUT_DIR/alicorn_sdl_gpu"
"$ODIN" test runtime
"$ODIN" test host/fonts "-collection:alicorn=$REPO_ROOT" "-out:$OUT_DIR/alicorn_host_fonts_tests"
alicorn_odin_with_linker_flags "$ODIN" "$ACCESSKIT_LINK_FLAGS" \
	test host/sdl3 "-collection:alicorn=$REPO_ROOT" "-out:$OUT_DIR/alicorn_sdl3_host_tests"
alicorn_odin_with_linker_flags "$ODIN" "$ACCESSKIT_LINK_FLAGS" \
	test host/sdl3/live_resize "-collection:alicorn=$REPO_ROOT" "-out:$OUT_DIR/alicorn_sdl3_live_resize_tests"
alicorn_odin_with_linker_flags "$ODIN" "$ACCESSKIT_LINK_FLAGS" \
	test host/sdl3/window_frame "-collection:alicorn=$REPO_ROOT" "-out:$OUT_DIR/alicorn_sdl3_window_frame_tests"
alicorn_odin_with_linker_flags "$ODIN" "$ACCESSKIT_LINK_FLAGS" \
	test host/sdl3/input "-collection:alicorn=$REPO_ROOT" "-out:$OUT_DIR/alicorn_sdl3_input_tests"
alicorn_odin_with_linker_flags "$ODIN" "$ACCESSKIT_LINK_FLAGS" \
	test host/sdl3/clipboard "-collection:alicorn=$REPO_ROOT" "-out:$OUT_DIR/alicorn_sdl3_clipboard_tests"
alicorn_odin_with_linker_flags "$ODIN" "$ACCESSKIT_LINK_FLAGS" \
	test host/sdl3/file_drag "-collection:alicorn=$REPO_ROOT" "-out:$OUT_DIR/alicorn_sdl3_file_drag_tests"
alicorn_odin_with_linker_flags "$ODIN" "$ACCESSKIT_LINK_FLAGS" \
	test host/sdl3/dialogs "-collection:alicorn=$REPO_ROOT" "-out:$OUT_DIR/alicorn_sdl3_dialog_tests"
alicorn_odin_with_linker_flags "$ODIN" "$ACCESSKIT_LINK_FLAGS" \
	test host/menus "-collection:alicorn=$REPO_ROOT" "-out:$OUT_DIR/alicorn_host_menus_tests"
"$ODIN" test host/web "-collection:alicorn=$REPO_ROOT" "-out:$OUT_DIR/alicorn_web_host_tests"
"$ODIN" test host/diagnostics "-collection:alicorn=$REPO_ROOT" "-out:$OUT_DIR/alicorn_diagnostics_tests"
alicorn_odin_with_linker_flags "$ODIN" "$ACCESSKIT_LINK_FLAGS" \
	test tests/fixtures/accessibility_contract \
	"-collection:alicorn=$REPO_ROOT" "-out:$OUT_DIR/accessibility_contract_tests"
alicorn_odin_with_linker_flags "$ODIN" "$ACCESSKIT_LINK_FLAGS" \
	test ui "-collection:alicorn=$REPO_ROOT" "-out:$OUT_DIR/alicorn_ui_tests"
"$ODIN" test testui "-collection:alicorn=$REPO_ROOT" "-out:$OUT_DIR/alicorn_testui_tests"
"$ODIN" test theme
"$ODIN" test renderer/cpu "-out:$OUT_DIR/alicorn_cpu_renderer_tests"
"$ODIN" build tools/theme "-out:$OUT_DIR/alicorn_theme"
"$OUT_DIR/alicorn_theme" check theme/testdata/minimal.json
"$OUT_DIR/alicorn_theme" check theme/testdata/extends_base.json
mkdir -p "$OUT_DIR/theme_codegen_smoke"
"$OUT_DIR/alicorn_theme" compile theme/testdata/minimal.json \
    --output "$OUT_DIR/theme_codegen_smoke/generated.odin" \
    --symbol TEST_THEME --runtime-import ../../runtime
"$ODIN" check "$OUT_DIR/theme_codegen_smoke" -no-entry-point
"$OUT_DIR/alicorn_theme" explain theme/testdata/minimal.json color.primary
if "$OUT_DIR/alicorn_theme" check theme/testdata/invalid.json; then
    echo 'theme CLI accepted an unsupported length unit' >&2
    exit 1
fi
alicorn_odin_with_linker_flags "$ODIN" "$ACCESSKIT_LINK_FLAGS" \
	test native/sdl_gpu "-collection:alicorn=$REPO_ROOT" "-out:$OUT_DIR/alicorn_native_tests"
alicorn_odin_with_linker_flags "$ODIN" "$ACCESSKIT_LINK_FLAGS" \
	test native/scroll_capture_tests "-collection:alicorn=$REPO_ROOT" "-out:$OUT_DIR/alicorn_scroll_capture_tests"
"$OUT_DIR/alicorn_sdl_gpu" --text-input-contract-test
sh "$SCRIPT_DIR/test_restoration.sh" "$ODIN"
