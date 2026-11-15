#!/bin/sh

# Install the native library paired with Odin's pinned vendor:wgpu bindings.
set -eu

if [ "$#" -ne 1 ]; then
	echo "Usage: sh tools/setup_macos_wgpu_native.sh /absolute/path/to/odin-root" >&2
	exit 2
fi

odin_root=$1
case "$odin_root" in
	/*) ;;
	*) echo 'Odin root must be an absolute path.' >&2; exit 2 ;;
esac
if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
	echo 'This bootstrap currently supports the macOS arm64 CI target only.' >&2
	exit 1
fi
if [ ! -f "$odin_root/vendor/wgpu/wgpu.odin" ]; then
	echo "Odin vendor:wgpu package not found under '$odin_root'." >&2
	exit 1
fi

release=v29.0.1.1
archive=wgpu-macos-aarch64-release.zip
sha=a5797a37b1adf720bcd5dcffb291edbbd5b7b14be0a3874c28e6393a655a7a3e
url="https://github.com/gfx-rs/wgpu-native/releases/download/$release/$archive"
stage=$(mktemp -d "${TMPDIR:-/tmp}/alicorn-wgpu-native.XXXXXX")
trap 'rm -rf "$stage"' 0
trap 'exit 1' 1 2 15

echo "Downloading pinned wgpu-native $release for macOS arm64"
curl --fail --location --silent --show-error --retry 3 "$url" -o "$stage/$archive"
actual_sha=$(shasum -a 256 "$stage/$archive" | awk '{print $1}')
if [ "$actual_sha" != "$sha" ]; then
	echo "wgpu-native archive SHA-256 mismatch. Expected $sha; got $actual_sha." >&2
	exit 1
fi

mkdir "$stage/extracted"
unzip -q "$stage/$archive" -d "$stage/extracted"
package="$stage/extracted/wgpu-macos-aarch64-release"
library="$package/lib/libwgpu_native.a"
if [ ! -f "$library" ]; then
	echo "Pinned wgpu-native archive is missing the expected static library: $library" >&2
	exit 1
fi

destination="$odin_root/vendor/wgpu/lib/wgpu-macos-aarch64-release"
mkdir -p "$destination"
cp -R "$package/." "$destination/"
if [ ! -f "$destination/lib/libwgpu_native.a" ]; then
	echo 'Could not install libwgpu_native.a into Odin vendor:wgpu.' >&2
	exit 1
fi
echo "Installed verified wgpu-native $release at $destination"
