#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)
OUT_DIR=$REPO_ROOT/out

. "$SCRIPT_DIR/common.sh"
ODIN_ARG=
if [ "$#" -eq 2 ] && [ "$1" = '--odin' ]; then
	ODIN_ARG=$2
elif [ "$#" -ne 0 ]; then
	echo "Usage: $0 [--odin PATH]" >&2
	exit 2
fi

ODIN=$(alicorn_resolve_odin "$ODIN_ARG")
mkdir -p "$OUT_DIR"
"$ODIN" build "$REPO_ROOT/tests/fixtures/web_ui_package" \
	"-collection:alicorn=$REPO_ROOT" -target:js_wasm32 \
	"-out:$OUT_DIR/web_ui_package.wasm"
printf 'WASM UI package check passed: %s\n' "$OUT_DIR/web_ui_package.wasm"
