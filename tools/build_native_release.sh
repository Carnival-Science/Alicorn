#!/bin/bash
# Packaging path for macOS. This script deliberately selects the static
# wgpu-native contract (ALICORN_DARWIN_STATIC_WGPU=1): bundled apps must not
# depend on the developer-machine rpath that the shared build/test selection
# adds. Native fixtures keep building against the shared dylib; see
# .github/workflows/webgpu-macos.yml, which exercises both halves together.
set -eu

usage() {
	cat >&2 <<'EOF'
Usage: build_native_release.sh [--odin PATH] [--metadata package.json] \
  [--sdl-linkage static|shared] [--output DIRECTORY] [--skip-smoke-test]
EOF
}

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)
ODIN_ARG=
METADATA=examples/01_hello/package.json
SDL_LINKAGE=static
OUTPUT=out/native-package/macos
SMOKE=1
while [ "$#" -gt 0 ]; do
	case "$1" in
		--odin) ODIN_ARG=$2; shift 2 ;;
		--metadata) METADATA=$2; shift 2 ;;
		--sdl-linkage) SDL_LINKAGE=$2; shift 2 ;;
		--output) OUTPUT=$2; shift 2 ;;
		--skip-smoke-test) SMOKE=0; shift ;;
		*) usage; exit 2 ;;
	esac
done
case "$SDL_LINKAGE" in static|shared) ;; *) usage; exit 2 ;; esac

. "$SCRIPT_DIR/common.sh"
. "$SCRIPT_DIR/macos_sdl.sh"
ODIN=$(alicorn_resolve_odin "$ODIN_ARG")
METADATA_PATH="$REPO_ROOT/$METADATA"
[ -f "$METADATA_PATH" ] || { echo "Metadata file not found: $METADATA_PATH" >&2; exit 2; }
APP_PACKAGE=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["odinPackage"])' "$METADATA_PATH")
APP_NAME=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["executableName"])' "$METADATA_PATH")
OUT_ROOT="$REPO_ROOT/out/native-package"
SDL_ROOT="$OUT_ROOT/sdl-3.4.20"
# Packages must not embed developer-machine rpaths and keep the static link
# contract. The shared wgpu-native selection is for build/test consumers that
# also link AccessKit; the packaged 01_hello does not import wgpu.
ALICORN_DARWIN_STATIC_WGPU=1
export ALICORN_DARWIN_STATIC_WGPU
alicorn_build_pinned_macos_sdl "$SDL_LINKAGE" "$SDL_ROOT"
SOURCE=$ALICORN_MACOS_SDL_SOURCE_DIR
PREFIX=$ALICORN_MACOS_SDL_PREFIX
SDL_RUNTIME=$ALICORN_MACOS_SDL_RUNTIME
SDL_LICENSE=$ALICORN_MACOS_SDL_LICENSE
SDL_VERSION=$ALICORN_MACOS_SDL_VERSION
ACCESSKIT_LINK_FLAGS=$(alicorn_accesskit_linker_flags)
ACCESSKIT_ROOT="$REPO_ROOT/.deps/accesskit/accesskit-c-0.23.1"
ACCESSKIT_BINDING_ROOT=$(alicorn_accesskit_binding_root)

for tool in python3; do
	command -v "$tool" >/dev/null 2>&1 || { echo "Required packaging tool not found: $tool" >&2; exit 127; }
done

SDL_LINK_FLAGS=
if [ "$SDL_LINKAGE" = static ]; then
	command -v pkg-config >/dev/null 2>&1 || { echo 'Static SDL link flags require pkg-config (install pkgconf).'; exit 127; }
	SDL_LINK_FLAGS="-L$PREFIX/lib"
	SDL_LINK_FLAGS="$SDL_LINK_FLAGS $(PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" pkg-config --static --libs-only-other sdl3)"
	# Odin's system:SDL3 import can retain a dylib load command even when the
	# pinned archive is on the search path. Force that archive into the
	# executable, then remove the now-unneeded dylib load command.
	SDL_LINK_FLAGS="$SDL_LINK_FLAGS -Wl,-force_load,$PREFIX/lib/libSDL3.a -Wl,-dead_strip_dylibs"
else
	SDL_LINK_FLAGS="-L$PREFIX/lib"
fi

BUILT="$OUT_ROOT/$APP_NAME"
cd "$REPO_ROOT"
if [ -n "$SDL_LINK_FLAGS" ]; then
	LINK_FLAGS="$ACCESSKIT_LINK_FLAGS $SDL_LINK_FLAGS"
else
	LINK_FLAGS="$ACCESSKIT_LINK_FLAGS"
fi
# The packaging link flags are explicit; do not let a CI-wide development
# rpath (ALICORN_SDL_LINK_FLAGS) leak into the bundled executable.
ALICORN_SKIP_SDL_LINK_FLAGS=1 alicorn_odin_with_linker_flags "$ODIN" "$LINK_FLAGS" \
	build "$APP_PACKAGE" "-collection:alicorn=$REPO_ROOT" "-out:$BUILT" -o:speed

# Fail fast if the shared build/test selection leaks its developer-machine
# rpath into a package. tools/package_macos.py audits the finished bundle too;
# checking here names the packaging contract before bundling begins.
if command -v otool >/dev/null 2>&1; then
	unexpected_rpaths=$(otool -l "$BUILT" | awk '
		$1 == "cmd" && $2 == "LC_RPATH" { expecting = 1; next }
		expecting && $1 == "path" { print $2; expecting = 0 }
	' | grep -Ev '^(@executable_path|@loader_path|/usr/lib|/System/Library)(/|$)' || true)
	if [ -n "$unexpected_rpaths" ]; then
		echo 'Packaged executable embeds an unexpected LC_RPATH:' >&2
		printf '%s\n' "$unexpected_rpaths" >&2
		echo 'Packaging must keep ALICORN_DARWIN_STATIC_WGPU=1 and avoid developer-machine rpaths.' >&2
		exit 1
	fi
fi

PACKAGE_ARGS=(
	"$SCRIPT_DIR/package_macos.py"
	--executable "$BUILT"
	--metadata "$METADATA_PATH"
	--linkage "$SDL_LINKAGE"
	--sdl-version "$SDL_VERSION"
	--sdl-license "$SDL_LICENSE"
	--accesskit-license-apache "$ACCESSKIT_ROOT/LICENSE-APACHE"
	--accesskit-license-mit "$ACCESSKIT_ROOT/LICENSE-MIT"
	--accesskit-license-chromium "$ACCESSKIT_ROOT/LICENSE.chromium"
	--accesskit-authors "$ACCESSKIT_ROOT/AUTHORS"
	--accesskit-binding-license "$ACCESSKIT_BINDING_ROOT/LICENSE"
)
case "$OUTPUT" in
	/*) PACKAGE_ARGS+=(--output "$OUTPUT") ;;
	*) PACKAGE_ARGS+=(--output "$REPO_ROOT/$OUTPUT") ;;
esac
if [ -n "$SDL_RUNTIME" ]; then PACKAGE_ARGS+=(--sdl-runtime "$SDL_RUNTIME"); fi
if [ -n "$SDL_RUNTIME" ]; then PACKAGE_ARGS+=(--sdl-runtime-provider pinned-source); fi
if [ "$SMOKE" -eq 1 ]; then PACKAGE_ARGS+=(--smoke-test); fi
python3 "${PACKAGE_ARGS[@]}"
