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
ODIN_ROOT=$("$ODIN" root)

cd "$SCRIPT_DIR"
mkdir -p out/web
"$ODIN" build . -collection:alicorn=../.. -target:js_wasm32 -o:size \
	-out:out/web/app.wasm -extra-linker-flags:--export-table
cp web/index.html out/web/index.html
cp "$ODIN_ROOT/core/sys/wasm/js/odin.js" out/web/odin.js
cp "$ODIN_ROOT/vendor/wgpu/wgpu.js" out/web/wgpu.js
node "$REPO_ROOT/tools/patch_odin_wgpu_js.js" out/web/wgpu.js
cp "$REPO_ROOT/host/web/demand_scheduler.js" out/web/alicorn_demand_scheduler.js
cp "$REPO_ROOT/host/web/accessibility_dom.js" out/web/alicorn_accessibility_dom.js
cp "$REPO_ROOT/host/web/webgpu_ui_host.js" out/web/alicorn_webgpu_host.js
printf 'Build complete: %s/out/web/app.wasm\n' "$SCRIPT_DIR"
printf 'Serve %s/out/web and open index.html in a WebGPU-capable browser.\n' "$SCRIPT_DIR"
