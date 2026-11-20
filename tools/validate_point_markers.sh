#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)
. "$SCRIPT_DIR/common.sh"
ODIN_ARG=
if [ "${1-}" = '--odin' ]; then
    if [ "$#" -lt 2 ]; then echo "Usage: $0 [--odin PATH] [--driver=metal|vulkan|direct3d12]" >&2; exit 2; fi
    ODIN_ARG=$2
    shift 2
fi
ODIN=$(alicorn_resolve_odin "$ODIN_ARG")
cd "$REPO_ROOT"
mkdir -p out/point-markers
ACCESSKIT_LINK_FLAGS=$(alicorn_accesskit_linker_flags)
# native/sdl_gpu now imports alicorn:host/sdl3; the collection is required even
# though this fixture has no WebGPU dependency.
alicorn_odin_with_linker_flags "$ODIN" "$ACCESSKIT_LINK_FLAGS" \
    build native/point_marker_validation_entry "-collection:alicorn=$REPO_ROOT" \
    -o:speed -out:out/alicorn_point_marker_validation
exec ./out/alicorn_point_marker_validation "$@"
