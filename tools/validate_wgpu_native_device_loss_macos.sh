#!/bin/sh

# Build (and, unless --build-only is given, run) the patched wgpu-native
# explicit-destroy callback probes on macOS arm64.
#
# Link contract: native macOS consumers that link the AccessKit static archive
# must use the shared wgpu-native dylib. AccessKit and static wgpu-native each
# ship a Rust runtime defining rust_eh_personality, which ld64 rejects. The
# validated fixture configuration is therefore shared wgpu-native via
# tools/common.sh; this script patches both the pinned static archive and the
# pinned dylib, and the probes link the dylib. ALICORN_DARWIN_STATIC_WGPU is
# the packaging opt-out (tools/build_native_release.sh) and is refused here.

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)
. "$SCRIPT_DIR/common.sh"

BUILD_ONLY=0
while [ "$#" -gt 0 ]; do
	case "$1" in
		--build-only) BUILD_ONLY=1; shift ;;
		*)
			echo "Usage: $0 [--build-only]" >&2
			exit 2
			;;
	esac
done

if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
	echo 'This validation currently requires macOS arm64 with Metal.' >&2
	exit 2
fi

if [ -n "${ALICORN_DARWIN_STATIC_WGPU:-}" ]; then
	echo 'The device-loss probe links the shared wgpu-native dylib; ALICORN_DARWIN_STATIC_WGPU selects the static packaging contract.' >&2
	echo 'Unset it to run this probe, or use tools/build_native_release.sh for the static package path.' >&2
	exit 2
fi

ODIN=$(alicorn_resolve_odin "${ALICORN_ODIN:-}")
ODIN_ROOT=$("$ODIN" root)
wgpu_lib_directory="$ODIN_ROOT/vendor/wgpu/lib/wgpu-macos-aarch64-release/lib"
wgpu_static="$wgpu_lib_directory/libwgpu_native.a"
wgpu_shared="$wgpu_lib_directory/libwgpu_native.dylib"
if [ ! -f "$wgpu_static" ] || [ ! -f "$wgpu_shared" ]; then
	echo "Pinned macOS wgpu-native libraries missing under '$wgpu_lib_directory' (need both libwgpu_native.a and libwgpu_native.dylib for the shared link contract)." >&2
	exit 1
fi

if [ "$BUILD_ONLY" -eq 0 ]; then
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
else
	llvm_prefix=
fi

release_commit=6aed50955d934ac36049ba8d002034841633ae02
patch_file="$REPO_ROOT/dependencies/patches/wgpu-native-v29.0.1.1-device-lost-callback.patch"
expected_patch_sha=AE569A401C4014B96567F7BF459DF938ECAE96174C2C39E94336D86AE9243D5E
actual_patch_sha=$(shasum -a 256 "$patch_file" | awk '{print toupper($1)}')
if [ "$actual_patch_sha" != "$expected_patch_sha" ]; then
	echo "Device-loss patch digest mismatch: expected $expected_patch_sha, got $actual_patch_sha." >&2
	exit 1
fi
routing_patch_file="$REPO_ROOT/dependencies/patches/wgpu-native-v29.0.1.1-device-loss-routing.patch"
expected_routing_patch_sha=81AB7D4F69A17F02FA7D9333E928C735BA0D5887EAE9EB9ED68E161C86D474F5
actual_routing_patch_sha=$(shasum -a 256 "$routing_patch_file" | awk '{print toupper($1)}')
if [ "$actual_routing_patch_sha" != "$expected_routing_patch_sha" ]; then
	echo "Device-loss routing patch digest mismatch: expected $expected_routing_patch_sha, got $actual_routing_patch_sha." >&2
	exit 1
fi

ACCESSKIT_LINK_FLAGS=$(alicorn_accesskit_linker_flags)

work=$(mktemp -d "${TMPDIR:-/tmp}/alicorn-wgpu-loss.XXXXXX")
static_backup="$work/libwgpu_native.a.original"
shared_backup="$work/libwgpu_native.dylib.original"
static_installed=0
shared_installed=0
cleanup() {
	result=$?
	trap - EXIT HUP INT TERM
	if [ "$static_installed" -eq 1 ] && [ -f "$static_backup" ]; then cp "$static_backup" "$wgpu_static"; fi
	if [ "$shared_installed" -eq 1 ] && [ -f "$shared_backup" ]; then cp "$shared_backup" "$wgpu_shared"; fi
	rm -rf "$work"
	exit "$result"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

if [ "$BUILD_ONLY" -eq 0 ]; then
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
	git -C "$source" apply --check "$routing_patch_file"
	git -C "$source" apply "$routing_patch_file"

	echo 'Building patched wgpu-native v29.0.1.1 with the Metal and WGSL features'
	(
		cd "$source"
		export WGPU_NATIVE_VERSION=29.0.1.1
		export LIBCLANG_PATH="$llvm_prefix/lib"
		export CARGO_TARGET_DIR="$work/target"
		cargo +1.93.1 build --release --locked --no-default-features --features wgsl,metal
	)

	patched_lib="$work/target/release/libwgpu_native.a"
	patched_shared="$work/target/release/libwgpu_native.dylib"
	if [ ! -f "$patched_lib" ] || [ ! -f "$patched_shared" ]; then
		echo 'Patched wgpu-native build did not produce both libwgpu_native.a and libwgpu_native.dylib.' >&2
		exit 1
	fi
	cp "$wgpu_static" "$static_backup"
	cp "$wgpu_shared" "$shared_backup"
	static_installed=1
	shared_installed=1
	cp "$patched_lib" "$wgpu_static"
	cp "$patched_shared" "$wgpu_shared"
	# Cargo's dylib id must resolve through the rpath that common.sh embeds;
	# an absolute target-directory id would break as soon as work/ is removed.
	install_name_tool -id "@rpath/libwgpu_native.dylib" "$wgpu_shared"
	# arm64 binaries carry an ad-hoc signature that install_name_tool breaks.
	codesign --force --sign - --timestamp=none "$wgpu_shared" >/dev/null
fi

cd "$REPO_ROOT/examples/15_webgpu_feasibility"
build_probe() {
	name=$1
	shift
	exe="$work/device-loss-$name"
	echo "Building Metal callback probe: $name"
	alicorn_odin_with_linker_flags "$ODIN" "$ACCESSKIT_LINK_FLAGS" build . "$@" \
		"-collection:alicorn=$REPO_ROOT" "-out:$exe"
	if [ "$BUILD_ONLY" -eq 0 ]; then
		"$exe"
	fi
}

build_probe process-events \
	-define:FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY=true \
	-define:FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY_EARLY=true
build_probe spontaneous \
	-define:FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY=true \
	-define:FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY_EARLY=true \
	-define:FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY_SPONTANEOUS_CALLBACK=true
build_probe release-before-poll \
	-define:FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY=true \
	-define:FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY_EARLY=true \
	-define:FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY_RELEASE_BEFORE_POLL=true
build_probe after-readback \
	-define:FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY=true
build_probe post-destroy-errors \
	-define:FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY=true \
	-define:FEASIBILITY_TEST_EXPLICIT_DEVICE_DESTROY_EARLY=true \
	-define:FEASIBILITY_TEST_WGPU_NATIVE_POST_DESTROY_ERRORS=true

if [ "$BUILD_ONLY" -eq 0 ]; then
	echo 'Patched macOS Metal explicit-destroy callback and post-destroy error-routing probes passed (not driver-loss tests).'
else
	echo 'Built the five Metal callback probes against the pinned shared wgpu-native configuration (--build-only: no Rust rebuild, no probe execution).'
fi
