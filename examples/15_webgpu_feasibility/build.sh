#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)
. "$REPO_ROOT/tools/common.sh"

ODIN_ARG=
if [ "${1-}" = '--odin' ]; then
	if [ "$#" -ne 2 ]; then
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

cd "$SCRIPT_DIR"
mkdir -p out web
echo 'Building interactive native fixture'
"$ODIN" build . -out:out/webgpu_feasibility
echo 'Building native asynchronous-readback smoke fixture'
"$ODIN" build . -define:FEASIBILITY_TEST_QUIT_AFTER_READBACK=true -out:out/webgpu_feasibility_smoke
echo 'Building native host-owned presenter smoke fixture'
"$ODIN" build . -define:FEASIBILITY_TEST_QUIT_AFTER_READBACK=true -define:FEASIBILITY_TEST_WEBGPU_PRESENTER=true -out:out/webgpu_feasibility_presenter_smoke
echo 'Building native SDL surface presenter smoke fixture'
"$ODIN" build . -define:FEASIBILITY_TEST_QUIT_AFTER_READBACK=true -define:FEASIBILITY_TEST_SURFACE_PRESENTER=true -out:out/webgpu_feasibility_surface_presenter
echo 'Building native surface-resize smoke fixture'
"$ODIN" build . -define:FEASIBILITY_TEST_QUIT_AFTER_READBACK=true -define:FEASIBILITY_TEST_RESIZE=true -out:out/webgpu_feasibility_resize_smoke
if ! command -v wasm-ld >/dev/null 2>&1; then
	echo 'The js_wasm32 build requires wasm-ld. On macOS install it with `brew install lld` and add `$(brew --prefix lld)/bin` to PATH.' >&2
	exit 1
fi
echo 'Building browser js_wasm32 fixture'
"$ODIN" build . -target:js_wasm32 -o:size -define:FEASIBILITY_TEST_WEB_CANVAS_PRESENTER=true -out:web/feasibility.wasm -extra-linker-flags:--export-table
ODIN_ROOT=$("$ODIN" root)
cp "$ODIN_ROOT/core/sys/wasm/js/odin.js" web/odin.js
cp "$ODIN_ROOT/vendor/wgpu/wgpu.js" web/wgpu.js
cp "$REPO_ROOT/host/web/demand_scheduler.js" web/alicorn_demand_scheduler.js
printf 'Native interactive: %s/out/webgpu_feasibility\n' "$SCRIPT_DIR"
printf 'Native readback smoke: %s/out/webgpu_feasibility_smoke\n' "$SCRIPT_DIR"
printf 'Native host-owned presenter smoke: %s/out/webgpu_feasibility_presenter_smoke\n' "$SCRIPT_DIR"
printf 'Native SDL surface presenter smoke: %s/out/webgpu_feasibility_surface_presenter\n' "$SCRIPT_DIR"
printf 'Native resize smoke: %s/out/webgpu_feasibility_resize_smoke\n' "$SCRIPT_DIR"
printf 'Browser shared-renderer fixture: serve %s/web on localhost and open /index.html\n' "$SCRIPT_DIR"
