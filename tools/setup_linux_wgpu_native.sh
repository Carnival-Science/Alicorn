#!/bin/sh

# Install the Linux x64 wgpu-native archive paired with Odin's pinned bindings.
set -eu

if [ "$#" -ne 1 ]; then
	echo "Usage: sh tools/setup_linux_wgpu_native.sh /absolute/path/to/odin-root" >&2
	exit 2
fi
odin_root=$1
case "$odin_root" in
	/*) ;;
	*) echo 'Odin root must be an absolute path.' >&2; exit 2 ;;
esac
if [ "$(uname -s)" != Linux ] || [ "$(uname -m)" != x86_64 ]; then
	echo 'This wgpu-native bootstrap currently supports Linux x86_64 only.' >&2
	exit 1
fi
if [ ! -f "$odin_root/vendor/wgpu/wgpu.odin" ]; then
	echo "Odin vendor:wgpu package not found under '$odin_root'." >&2
	exit 1
fi

release=v29.0.1.1
archive=wgpu-linux-x86_64-release.zip
sha=95a4d90c071005a98d03eab348beaa6b07e16eb00d1dcdb9f8348f75eb97ec5a
url="https://github.com/gfx-rs/wgpu-native/releases/download/$release/$archive"
stage=$(mktemp -d "${TMPDIR:-/tmp}/alicorn-wgpu-native.XXXXXX")
trap 'rm -rf "$stage"' 0
trap 'exit 1' 1 2 15

echo "Downloading pinned wgpu-native $release for Linux x86_64"
curl --fail --location --silent --show-error --retry 3 "$url" -o "$stage/$archive"
actual_sha=$(sha256sum "$stage/$archive" | awk '{print $1}')
if [ "$actual_sha" != "$sha" ]; then
	echo "wgpu-native archive SHA-256 mismatch. Expected $sha; got $actual_sha." >&2
	exit 1
fi
echo "Verified SHA-256: $sha"

mkdir "$stage/extracted"
unzip -q "$stage/$archive" -d "$stage/extracted"
library=$(find "$stage/extracted" -type f -name libwgpu_native.a -print -quit)
if [ -z "$library" ]; then
	echo 'Pinned wgpu-native archive is missing libwgpu_native.a.' >&2
	exit 1
fi
package=$(dirname -- "$(dirname -- "$library")")
destination="$odin_root/vendor/wgpu/lib/wgpu-linux-x86_64-release"
mkdir -p "$destination"
cp -R "$package/." "$destination/"
if [ ! -f "$destination/lib/libwgpu_native.a" ]; then
	echo 'Could not install libwgpu_native.a into Odin vendor:wgpu.' >&2
	exit 1
fi
echo "Installed verified wgpu-native $release at $destination"
