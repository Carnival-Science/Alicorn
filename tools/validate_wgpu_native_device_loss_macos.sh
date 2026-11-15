#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)
. "$SCRIPT_DIR/common.sh"

if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
	echo 'This validation currently requires macOS arm64 with Metal.' >&2
	exit 2
fi

ODIN=$(alicorn_resolve_odin "${ALICORN_ODIN:-}")
ODIN_ROOT=$("$ODIN" root)
if [ ! -f "$ODIN_ROOT/vendor/wgpu/lib/wgpu-macos-aarch64-release/lib/libwgpu_native.a" ]; then
	echo "Pinned macOS wgpu-native library missing under '$ODIN_ROOT'." >&2
	exit 1
fi

if ! command -v rustup >/dev/null 2>&1 || ! command -v cargo >/dev/null 2>&1; then
	echo 'The patched wgpu-native probe requires rustup and cargo.' >&2
	exit 1
fi
if ! command -v brew >/dev/null 2>&1; then
	echo 'The patched wgpu-native probe requires Homebrew LLVM for bindgen.' >&2
	exit 1
fi
llvm_prefix=$(brew --prefix llvm)
if [ ! -f "$llvm_prefix/lib/libclang.dylib" ]; then
	echo "libclang.dylib not found under '$llvm_prefix/lib'." >&2
	exit 1
fi

release_commit=6aed50955d934ac36049ba8d002034841633ae02
patch_file="$REPO_ROOT/dependencies/patches/wgpu-native-v29.0.1.1-device-lost-callback.patch"
expected_patch_sha=AE569A401C4014B96567F7BF459DF938ECAE96174C2C39E94336D86AE9243D5E
actual_patch_sha=$(shasum -a 256 "$patch_file" | awk '{print toupper($1)}')
if [ "$actual_patch_sha" != "$expected_patch_sha" ]; then
	echo "Device-loss patch digest mismatch: expected $expected_patch_sha, got $actual_patch_sha." >&2
	exit 1
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/alicorn-wgpu-loss.XXXXXX")
wgpu_lib="$ODIN_ROOT/vendor/wgpu/lib/wgpu-macos-aarch64-release/lib/libwgpu_native.a"
backup="$work/libwgpu_native.a.original"
cleanup() {
	result=$?
	trap - EXIT HUP INT TERM
	if [ -f "$backup" ]; then cp "$backup" "$wgpu_lib"; fi
	rm -rf "$work"
	exit "$result"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

rustup toolchain install 1.93.1 --profile minimal
source="$work/wgpu-native"
git clone --recurse-submodules --branch v29.0.1.1 \
	https://github.com/gfx-rs/wgpu-native.git "$source"
if [ "$(git -C "$source" rev-parse HEAD)" != "$release_commit" ]; then
	echo 'Cloned wgpu-native source does not match the recorded v29.0.1.1 commit.' >&2
	exit 1
fi
git -C "$source" apply --check "$patch_file"
git -C "$source" apply "$patch_file"

echo 'Building patched wgpu-native v29.0.1.1 with the Metal and WGSL features'
(
	cd "$source"
	export WGPU_NATIVE_VERSION=29.0.1.1
	export LIBCLANG_PATH="$llvm_prefix/lib"
	export CARGO_TARGET_DIR="$work/target"
	cargo +1.93.1 build --release --locked --no-default-features --features wgsl,metal
)

patched_lib="$work/target/release/libwgpu_native.a"
if [ ! -f "$patched_lib" ]; then
	echo 'Patched wgpu-native build did not produce libwgpu_native.a.' >&2
	exit 1
fi
cp "$wgpu_lib" "$backup"
cp "$patched_lib" "$wgpu_lib"

cd "$REPO_ROOT/examples/15_webgpu_feasibility"
build_and_run() {
	name=$1
	shift
	exe="$work/device-loss-$name"
	echo "Building and running patched Metal callback probe: $name"
	"$ODIN" build . "$@" "-out:$exe"
	"$exe"
}

build_and_run process-events \
	-define:FEASIBILITY_TEST_DEVICE_LOSS=true \
	-define:FEASIBILITY_TEST_DEVICE_LOSS_EARLY=true
build_and_run spontaneous \
	-define:FEASIBILITY_TEST_DEVICE_LOSS=true \
	-define:FEASIBILITY_TEST_DEVICE_LOSS_EARLY=true \
	-define:FEASIBILITY_TEST_DEVICE_LOSS_SPONTANEOUS=true
build_and_run release-before-poll \
	-define:FEASIBILITY_TEST_DEVICE_LOSS=true \
	-define:FEASIBILITY_TEST_DEVICE_LOSS_EARLY=true \
	-define:FEASIBILITY_TEST_DEVICE_LOSS_RELEASE_BEFORE_POLL=true
build_and_run after-readback \
	-define:FEASIBILITY_TEST_DEVICE_LOSS=true

echo 'Patched macOS Metal device-loss callback probes passed.'
