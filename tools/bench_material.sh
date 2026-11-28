#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT=$ROOT
source "$ROOT/tools/common.sh"
ODIN_ARG=
if [ "${1-}" = "--odin" ]; then
    if [ "$#" -lt 2 ]; then
        echo "Usage: $0 [--odin PATH] [benchmark arguments...]" >&2
        exit 2
    fi
    ODIN_ARG=$2
    shift 2
elif [ "${1-}" != "" ] && [ "${1#--}" = "$1" ]; then
    ODIN_ARG=$1
    shift
fi
ODIN="$(alicorn_resolve_odin "$ODIN_ARG")"
mkdir -p "$ROOT/out"
ACCESSKIT_LINK_FLAGS=$(alicorn_accesskit_linker_flags)
alicorn_odin_with_linker_flags "$ODIN" "$ACCESSKIT_LINK_FLAGS" build "$ROOT/benchmarks/native_material" -o:speed -out:"$ROOT/out/alicorn_material_benchmark"
"$ROOT/out/alicorn_material_benchmark" "$@"
if [ "${1-}" = "--issue248-retention-only" ]; then
    exit 0
fi
alicorn_odin_with_linker_flags "$ODIN" "$ACCESSKIT_LINK_FLAGS" build "$ROOT/benchmarks/native_material_budget" "-collection:alicorn=$REPO_ROOT" -o:speed -out:"$ROOT/out/alicorn_material_budget"
"$ROOT/out/alicorn_material_budget"
