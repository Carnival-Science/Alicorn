alicorn_resolve_odin() {
	requested=${1-}
	source='--odin'
	if [ -z "$requested" ]; then
		requested=${ALICORN_ODIN:-}
		source='ALICORN_ODIN'
	fi
	if [ -z "$requested" ]; then
		requested=odin
		source='PATH'
	fi

	case "$requested" in
		*/*)
			resolved=$requested
			if [ ! -f "$resolved" ] || [ ! -x "$resolved" ]; then
				echo "Odin executable not found or not executable: $requested (from $source)" >&2
				return 127
			fi
			;;
		*)
			resolved=$(command -v "$requested" 2>/dev/null || true)
			if [ -z "$resolved" ] || [ ! -f "$resolved" ] || [ ! -x "$resolved" ]; then
				if [ "$source" = 'PATH' ]; then
					cat >&2 <<'EOF'
Odin was not found.

Install Odin: https://odin-lang.org/docs/install/
Then add the Odin directory to PATH, or set ALICORN_ODIN to the compiler executable.
EOF
				else
					echo "Odin executable '$requested' was not found (from $source)." >&2
				fi
				return 127
			fi
			;;
	esac

	case "$resolved" in
		/*) ;;
		*)
			resolved_dir=$(CDPATH='' cd -- "$(dirname -- "$resolved")" && pwd -P) || return 127
			resolved=$resolved_dir/$(basename -- "$resolved")
			;;
	esac

	printf '%s\n' "$resolved"
}

# AccessKit and static wgpu-native each ship a Rust runtime that defines
# rust_eh_personality. macOS ld64 rejects the duplicate symbol, so native
# consumers link Odin's shared wgpu-native dylib instead, matching the Windows
# and Unix example policy. The absolute rpath keeps the dylib resolvable
# without DYLD_LIBRARY_PATH.
alicorn_macos_shared_wgpu_flags() {
	[ "$(uname -s)" = Darwin ] || return 0
	case "$(uname -m)" in
		arm64|aarch64) alicorn_wgpu_arch=aarch64 ;;
		x86_64) alicorn_wgpu_arch=x86_64 ;;
		*) echo "Unsupported macOS architecture: $(uname -m)" >&2; return 1 ;;
	esac
	alicorn_wgpu_lib_directory=$(dirname -- "$1")/vendor/wgpu/lib/wgpu-macos-$alicorn_wgpu_arch-release/lib
	printf '%s\n' "-Wl,-rpath,$alicorn_wgpu_lib_directory"
}

# Native callers need the standalone binding collection even when no native
# linker flags are required. Keep each compiler argument separate.
alicorn_odin_with_linker_flags() {
	alicorn_odin_executable=$1
	alicorn_linker_flags=$2
	shift 2
	if [ "$(uname -s)" = Darwin ] && [ -z "${ALICORN_DARWIN_STATIC_WGPU:-}" ]; then
		alicorn_has_wgpu_shared=0
		for alicorn_argument in "$@"; do
			case "$alicorn_argument" in
				-define:WGPU_SHARED=*) alicorn_has_wgpu_shared=1 ;;
			esac
		done
		if [ "$alicorn_has_wgpu_shared" -eq 0 ]; then
			set -- "$@" -define:WGPU_SHARED=true
		fi
		alicorn_wgpu_shared_flags=$(alicorn_macos_shared_wgpu_flags "$alicorn_odin_executable") || return $?
		if [ -n "$alicorn_wgpu_shared_flags" ]; then
			if [ -n "$alicorn_linker_flags" ]; then
				alicorn_linker_flags="$alicorn_linker_flags $alicorn_wgpu_shared_flags"
			else
				alicorn_linker_flags=$alicorn_wgpu_shared_flags
			fi
		fi
	fi
	if [ -n "${ALICORN_SDL_LINK_FLAGS:-}" ] &&
	   [ -z "${ALICORN_SKIP_SDL_LINK_FLAGS:-}" ]; then
		if [ -n "$alicorn_linker_flags" ]; then
			alicorn_linker_flags="$alicorn_linker_flags $ALICORN_SDL_LINK_FLAGS"
		else
			alicorn_linker_flags=$ALICORN_SDL_LINK_FLAGS
		fi
	fi
	alicorn_binding_root=$(alicorn_accesskit_binding_root) || return $?
	alicorn_c_library_directory=$(alicorn_accesskit_library_directory) || return $?
	if [ -n "$alicorn_linker_flags" ]; then
		"$alicorn_odin_executable" "$@" "-collection:accesskit=$alicorn_binding_root" "-collection:accesskit_c=$alicorn_c_library_directory" "-extra-linker-flags:$alicorn_linker_flags"
	else
		"$alicorn_odin_executable" "$@" "-collection:accesskit=$alicorn_binding_root" "-collection:accesskit_c=$alicorn_c_library_directory"
	fi
}

# Most callers are under tools/, where $0 is enough even in POSIX sh. A nested
# example build script has a different $0 directory, so prefer its established
# repository root when available.
if [ -n "${REPO_ROOT:-}" ]; then
	_alicorn_common_tools_dir=$REPO_ROOT/tools
else
	_alicorn_common_tools_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE:-$0}")" && pwd -P)
fi
. "$_alicorn_common_tools_dir/accesskit.sh"
unset _alicorn_common_tools_dir
