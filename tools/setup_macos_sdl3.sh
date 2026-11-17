#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)
BUILD_ROOT=${1:-"$REPO_ROOT/out/native-package/sdl-3.4.18/shared"}
VERSION=3.4.18
URL='https://github.com/libsdl-org/SDL/releases/download/release-3.4.18/SDL3-3.4.18.tar.gz'
SHA256=9c75cf16330322c217dedd2e0609f1124f1b54b8633e763467b4684d0f4334a3
ARCHIVE="$BUILD_ROOT/SDL3-$VERSION.tar.gz"
SOURCE="$BUILD_ROOT/source"
BUILD="$BUILD_ROOT/build"
PREFIX="$BUILD_ROOT/prefix"

for tool in cmake curl pkg-config shasum tar; do
	command -v "$tool" >/dev/null 2>&1 || { echo "Required SDL build tool not found: $tool" >&2; exit 127; }
done

mkdir -p "$BUILD_ROOT"
if [ ! -f "$ARCHIVE" ]; then curl -fL "$URL" -o "$ARCHIVE"; fi
actual_sha=$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')
[ "$actual_sha" = "$SHA256" ] || {
	echo "Pinned SDL source checksum mismatch: $actual_sha" >&2
	exit 1
}
if [ ! -f "$SOURCE/CMakeLists.txt" ]; then
	mkdir -p "$SOURCE"
	tar -xzf "$ARCHIVE" --strip-components=1 -C "$SOURCE"
fi

cmake -S "$SOURCE" -B "$BUILD" \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_INSTALL_PREFIX="$PREFIX" \
	-DSDL_SHARED=ON -DSDL_STATIC=OFF \
	-DSDL_TEST_LIBRARY=OFF -DSDL_TESTS=OFF \
	-DSDL_INSTALL_TESTS=OFF -DSDL_DISABLE_INSTALL_DOCS=ON \
	-DSDL_FRAMEWORK=OFF -DSDL_RPATH=OFF
cmake --build "$BUILD" --config Release --target SDL3-shared
cmake --install "$BUILD" --config Release

version=$(PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" pkg-config --modversion sdl3)
[ "$version" = "$VERSION" ] || {
	echo "Pinned SDL installation reports $version, expected $VERSION." >&2
	exit 1
}
runtime=$(find "$PREFIX/lib" -maxdepth 1 -type f -name 'libSDL3*.dylib' | sort | head -n 1)
[ -n "$runtime" ] || { echo "No SDL3 dylib found under $PREFIX/lib." >&2; exit 1; }

echo "Installed checksum-verified SDL $version at $PREFIX"
echo "$PREFIX"
