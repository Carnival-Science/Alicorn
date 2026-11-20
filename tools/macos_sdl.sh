#!/bin/bash

# Shared pinned-SDL build used by macOS package and native-host workflows.
ALICORN_MACOS_SDL_PIN_VERSION=3.4.20
ALICORN_MACOS_SDL_PIN_URL='https://github.com/libsdl-org/SDL/releases/download/release-3.4.20/SDL3-3.4.20.tar.gz'
ALICORN_MACOS_SDL_PIN_SHA256='f3bb06f55bed9557227a700af2ea62e49497ebdf58037732a731a5fb3ef8581f'

alicorn_build_pinned_macos_sdl() {
	if [ "$#" -ne 2 ]; then
		echo 'Usage: alicorn_build_pinned_macos_sdl static|shared BUILD_ROOT' >&2
		return 2
	fi

	local linkage=$1
	local root=$2
	local archive source build prefix actual_sha runtime
	case "$linkage" in static|shared) ;; *) echo "Unsupported SDL linkage: $linkage" >&2; return 2 ;; esac

	for tool in cmake curl shasum tar; do
		command -v "$tool" >/dev/null 2>&1 || { echo "Required SDL build tool not found: $tool" >&2; return 127; }
	done

	archive="$root/SDL3-$ALICORN_MACOS_SDL_PIN_VERSION.tar.gz"
	source="$root/source"
	build="$root/build-$linkage"
	prefix="$root/prefix-$linkage"
	mkdir -p "$root"
	if [ ! -f "$archive" ]; then curl -fL "$ALICORN_MACOS_SDL_PIN_URL" -o "$archive"; fi
	actual_sha=$(shasum -a 256 "$archive" | awk '{print $1}')
	[ "$actual_sha" = "$ALICORN_MACOS_SDL_PIN_SHA256" ] || {
		echo "Pinned SDL source checksum mismatch: $actual_sha" >&2
		return 1
	}
	if [ ! -f "$source/CMakeLists.txt" ]; then
		mkdir -p "$source"
		tar -xzf "$archive" --strip-components=1 -C "$source"
	fi
	[ -f "$source/LICENSE.txt" ] || { echo 'Pinned SDL source is missing LICENSE.txt.' >&2; return 1; }

	if [ "$linkage" = static ]; then
		if [ ! -f "$build/CMakeCache.txt" ]; then
			cmake -S "$source" -B "$build" \
				-DCMAKE_BUILD_TYPE=Release \
				-DCMAKE_INSTALL_PREFIX="$prefix" \
				-DSDL_SHARED=OFF -DSDL_STATIC=ON \
				-DSDL_TEST_LIBRARY=OFF -DSDL_TESTS=OFF \
				-DSDL_INSTALL_TESTS=OFF -DSDL_DISABLE_INSTALL_DOCS=ON \
				-DSDL_FRAMEWORK=OFF -DSDL_RPATH=OFF
		fi
		cmake --build "$build" --config Release --target SDL3-static
	else
		if [ ! -f "$build/CMakeCache.txt" ]; then
			cmake -S "$source" -B "$build" \
				-DCMAKE_BUILD_TYPE=Release \
				-DCMAKE_INSTALL_PREFIX="$prefix" \
				-DSDL_SHARED=ON -DSDL_STATIC=OFF \
				-DSDL_TEST_LIBRARY=OFF -DSDL_TESTS=OFF \
				-DSDL_INSTALL_TESTS=OFF -DSDL_DISABLE_INSTALL_DOCS=ON \
				-DSDL_FRAMEWORK=OFF -DSDL_RPATH=OFF
		fi
		cmake --build "$build" --config Release --target SDL3-shared
	fi
	cmake --install "$build" --config Release

	runtime=
	if [ "$linkage" = shared ]; then
		runtime=$(find "$prefix/lib" -maxdepth 1 -type f -name 'libSDL3*.dylib' | sort | head -n 1)
		[ -n "$runtime" ] || { echo "No SDL3 dylib found under pinned prefix $prefix/lib." >&2; return 1; }
	fi

	ALICORN_MACOS_SDL_SOURCE_DIR=$source
	ALICORN_MACOS_SDL_PREFIX=$prefix
	ALICORN_MACOS_SDL_RUNTIME=$runtime
	ALICORN_MACOS_SDL_LICENSE=$source/LICENSE.txt
	ALICORN_MACOS_SDL_VERSION=$ALICORN_MACOS_SDL_PIN_VERSION
}
