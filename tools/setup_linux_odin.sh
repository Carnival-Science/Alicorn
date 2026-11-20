#!/bin/sh

# Install the exact Odin Linux x64 SDK used by WebGPU feasibility CI.
set -eu

if [ "$#" -ne 1 ]; then
	echo "Usage: sh tools/setup_linux_odin.sh /absolute/path/to/new/odin-directory" >&2
	exit 2
fi
destination=$1
case "$destination" in
	/*) ;;
	*) echo 'Odin destination must be an absolute path.' >&2; exit 2 ;;
esac
if [ -e "$destination" ] || [ -L "$destination" ]; then
	echo "Odin destination already exists: $destination. Choose a fresh directory." >&2
	exit 1
fi
if [ "$(uname -s)" != Linux ] || [ "$(uname -m)" != x86_64 ]; then
	echo 'This Odin bootstrap currently supports Linux x86_64 only.' >&2
	exit 1
fi

release=dev-2026-11
archive=odin-linux-amd64-dev-2026-11.tar.gz
sha=65c9f6e97d6f8a30930e151f270ce5aeaa98fe8b2ba49fe067394e2af04f7618
expected_version='dev-2026-11-nightly:9a69916'

parent=$(dirname -- "$destination")
mkdir -p "$parent"
stage=$(mktemp -d "$parent/.alicorn-odin.XXXXXX")
trap 'rm -rf "$stage"' 0
trap 'exit 1' 1 2 15

url="https://github.com/odin-lang/Odin/releases/download/$release/$archive"
echo "Downloading pinned Odin $release for Linux x86_64"
curl --fail --location --silent --show-error --retry 3 "$url" -o "$stage/$archive"
actual_sha=$(sha256sum "$stage/$archive" | awk '{print $1}')
if [ "$actual_sha" != "$sha" ]; then
	echo "Odin archive SHA-256 mismatch. Expected $sha; got $actual_sha." >&2
	exit 1
fi
echo "Verified SHA-256: $sha"

mkdir "$stage/sdk"
tar -xzf "$stage/$archive" --strip-components=1 -C "$stage/sdk"
version=$(ODIN_ROOT="$stage/sdk" "$stage/sdk/odin" version)
case "$version" in
	*" version $expected_version") ;;
	*) echo "Unexpected Odin compiler version: $version" >&2; exit 1 ;;
esac
for directory in base core vendor shared; do
	if [ ! -d "$stage/sdk/$directory" ]; then
		echo "Verified Odin archive is missing SDK directory: $directory" >&2
		exit 1
	fi
done
mv "$stage/sdk" "$destination"
echo "Installed Odin at $destination ($expected_version)"
