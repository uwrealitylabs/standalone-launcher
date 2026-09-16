#!/usr/bin/env bash
#
# Fetches and builds the pinned native dependencies for the Wayland compositor
# GDExtension. Linux only -- wlroots does not exist elsewhere.
#
# wlroots 0.20.2 is newer than what current stable distributions ship, so this
# script builds whatever the host is missing into a private prefix. On Debian
# trixie that is all five of wayland, wayland-protocols, libdrm, libxkbcommon
# and pixman; on a newer host it may be none of them. Each is skipped when
# pkg-config already reports a new enough system copy.
#
# Idempotent: a tree already at the pinned commit is left alone, and a tree that
# is partial, dirty or at the wrong commit is deleted and refetched rather than
# patched in place. Half-updated dependency trees produce link errors that look
# like source bugs, which costs far more than the occasional refetch.
#
#     native/setup.sh          # fetch and build what is missing
#     native/setup.sh --force  # discard and rebuild everything

set -euo pipefail

# --- pins ---------------------------------------------------------------
# Tags are movable, so wlroots and godot-cpp are pinned to the commit each
# resolved to. Changing a pin is a deliberate act: update it here and note it
# in native/README.md.
GODOT_CPP_REPO="https://github.com/godotengine/godot-cpp.git"
GODOT_CPP_TAG="godot-4.5-stable"
GODOT_CPP_SHA="e83fd0904c13356ed1d4c3d09f8bb9132bdc6b77"

WLROOTS_REPO="https://gitlab.freedesktop.org/wlroots/wlroots.git"
WLROOTS_TAG="0.20.2"
WLROOTS_SHA="d783533489e1f75d6886c2ab5c5960090ef268f8"

# Minimums are wlroots 0.20.2's own, read off its meson.build; the pinned tags
# are the first releases that satisfy them.
#   name | pkg-config module | minimum | git tag | repo
DEPS=(
	"wayland|wayland-server|1.24.0|1.24.0|https://gitlab.freedesktop.org/wayland/wayland.git"
	"wayland-protocols|wayland-protocols|1.47|1.47|https://gitlab.freedesktop.org/wayland/wayland-protocols.git"
	"libdrm|libdrm|2.4.129|libdrm-2.4.129|https://gitlab.freedesktop.org/mesa/drm.git"
	"libxkbcommon|xkbcommon|1.8.0|xkbcommon-1.8.1|https://github.com/xkbcommon/libxkbcommon.git"
	"pixman|pixman-1|0.46.0|pixman-0.46.4|https://gitlab.freedesktop.org/pixman/pixman.git"
)

# Meson options per dependency: build the libraries, skip docs, tests and the
# hardware drivers none of this needs.
meson_opts_for() {
	case "$1" in
	wayland) echo "-Ddocumentation=false -Dtests=false" ;;
	wayland-protocols) echo "-Dtests=false" ;;
	libdrm) echo "-Dintel=disabled -Dradeon=disabled -Damdgpu=disabled
		-Dnouveau=disabled -Dvmwgfx=disabled -Domap=disabled
		-Dexynos=disabled -Dfreedreno=disabled -Dtegra=disabled
		-Dvc4=disabled -Detnaviv=disabled -Dman-pages=disabled
		-Dtests=false -Dcairo-tests=disabled" ;;
	libxkbcommon) echo "-Denable-docs=false -Denable-wayland=false
		-Denable-x11=false -Denable-xkbregistry=false -Denable-tools=false" ;;
	pixman) echo "-Dtests=disabled -Ddemos=disabled -Dgtk=disabled" ;;
	*) echo "" ;;
	esac
}

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
deps="$here/.deps"
src="$deps/src"
prefix="$deps/prefix"
force=0
[ "${1:-}" = "--force" ] && force=1

log() { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Linux" ] || die "Linux only: wlroots does not build on $(uname -s).
    The pixel conversion unit tests do run everywhere:
      godot --headless --xr-mode off --path . --script res://tests/pixel_convert_check.gd"

# --- host prerequisites -------------------------------------------------
missing=()
for tool in git meson ninja pkg-config scons cc bison flex; do
	command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [ ${#missing[@]} -gt 0 ]; then
	die "missing build tools: ${missing[*]}
    Debian/Ubuntu: sudo apt install -y git meson ninja-build pkg-config scons \\
        build-essential bison flex libffi-dev libexpat1-dev libxml2-dev \\
        libseat-dev hwdata"
fi

# weston-simple-shm is the proof-of-concept test client. Checked here rather than
# discovered missing at demo time, when it reads as a compositor failure.
if ! command -v weston-simple-shm >/dev/null 2>&1; then
	warn "weston-simple-shm not on PATH; install it before running the demo"
	printf '    Debian/Ubuntu: sudo apt install -y weston\n'
fi

# Everything below resolves against the private prefix first, then the system.
#
# meson chooses the libdir at install time -- lib/, lib64/, or a multiarch
# lib/<triplet>/ on Debian derivatives -- and that directory does not exist on a
# clean tree until the first dependency has been installed. Computing the glob
# once at startup therefore silently misses the prefix on exactly the run that
# matters, so it is recomputed after every install instead.
system_pkg_path="${PKG_CONFIG_PATH:-}"

refresh_pkg_path() {
	local path="$prefix/lib/pkgconfig:$prefix/lib64/pkgconfig:$prefix/share/pkgconfig"
	local d
	for d in "$prefix"/lib/*-linux-*/pkgconfig; do
		[ -d "$d" ] && path="$d:$path"
	done
	export PKG_CONFIG_PATH="$path${system_pkg_path:+:$system_pkg_path}"
}

refresh_pkg_path
export PATH="$prefix/bin:$PATH"

# Clones $1 into $2 at exactly $3, refetching when the tree is absent, dirty or
# parked on some other commit.
checkout_pinned() {
	local repo="$1" dir="$2" rev="$3" name="$4"

	if [ "$force" -eq 1 ] && [ -d "$dir" ]; then
		log "$name: --force, discarding"
		rm -rf "$dir"
	fi

	if [ -d "$dir/.git" ]; then
		local want head dirty
		want="$(git -C "$dir" rev-parse --verify --quiet "$rev^{commit}" || echo "")"
		head="$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo none)"
		dirty="$(git -C "$dir" status --porcelain 2>/dev/null | head -1)"
		if [ -n "$want" ] && [ "$head" = "$want" ] && [ -z "$dirty" ]; then
			log "$name: already at ${head:0:12}"
			return 0
		fi
		log "$name: at ${head:0:12}${dirty:+ (dirty)}, want $rev -- refetching"
		rm -rf "$dir"
	elif [ -e "$dir" ]; then
		log "$name: not a git tree, discarding"
		rm -rf "$dir"
	fi

	log "$name: cloning at $rev"
	git clone --quiet --filter=blob:none "$repo" "$dir"
	git -C "$dir" checkout --quiet --detach "$rev"
}

# Builds one meson dependency into the private prefix, unless the system copy
# already satisfies the minimum.
build_dep() {
	local name="$1" module="$2" minimum="$3" rev="$4" repo="$5"
	local dir="$src/$name" stamp="$prefix/.built-$name-$rev"

	if [ "$force" -eq 0 ] && pkg-config --atleast-version="$minimum" "$module" \
			2>/dev/null; then
		# Could be the system copy or one this script built earlier -- both
		# are on PKG_CONFIG_PATH by now, and either is equally fine.
		log "$name: $module $(pkg-config --modversion "$module") satisfies >= $minimum"
		return 0
	fi
	if [ "$force" -eq 0 ] && [ -f "$stamp" ]; then
		log "$name: already built at $rev"
		return 0
	fi

	checkout_pinned "$repo" "$dir" "$rev" "$name"
	log "$name: building (system copy is older than $minimum)"
	rm -rf "$dir/build"
	# Static, for the same reason wlroots is: a dependency built here does not
	# exist on the board, so it has to end up inside the extension .so. Built
	# shared it becomes a NEEDED entry that the loader satisfies from the
	# system's older copy, and the extension fails to load on a missing symbol.
	# A dependency the system already satisfies is skipped above and stays a
	# normal dynamic system library.
	# shellcheck disable=SC2046  # options are intentionally word-split
	meson setup "$dir/build" "$dir" --prefix="$prefix" --buildtype=release \
		--default-library=static $(meson_opts_for "$name") >/dev/null
	ninja -C "$dir/build" install >/dev/null
	refresh_pkg_path
	touch "$stamp"
}

mkdir -p "$src"

for spec in "${DEPS[@]}"; do
	IFS='|' read -r name module minimum rev repo <<<"$spec"
	build_dep "$name" "$module" "$minimum" "$rev" "$repo"
done

checkout_pinned "$GODOT_CPP_REPO" "$here/godot-cpp" "$GODOT_CPP_SHA" \
	"godot-cpp $GODOT_CPP_TAG"
checkout_pinned "$WLROOTS_REPO" "$src/wlroots" "$WLROOTS_SHA" \
	"wlroots $WLROOTS_TAG"

# --- wlroots ------------------------------------------------------------
# Built static and linked into the extension so deployment to the board is one
# file. A shared build against this private prefix links fine here and then
# fails to load on the board unless RPATH and the whole transitive closure are
# shipped too -- see native/README.md.
#
# -Dbackends= and -Drenderers= drop the DRM/libinput backends and the GLES and
# Vulkan renderers. The Pixman renderer is not optional and is always compiled
# in, which is why pixman stays a hard dependency above.
stamp="$prefix/.built-wlroots-$WLROOTS_SHA"
if [ -f "$stamp" ] && [ "$force" -eq 0 ]; then
	log "wlroots: already built at $WLROOTS_SHA"
else
	log "wlroots: configuring (static)"
	rm -rf "$src/wlroots/build"
	meson setup "$src/wlroots/build" "$src/wlroots" \
		--prefix="$prefix" \
		--default-library=static \
		--buildtype=release \
		-Dexamples=false \
		-Dwerror=false \
		-Dxwayland=disabled \
		-Dbackends= \
		-Drenderers=
	log "wlroots: building"
	ninja -C "$src/wlroots/build" install >/dev/null
	touch "$stamp"
fi

pkg-config --exists wlroots-0.20 \
	|| die "wlroots installed but pkg-config cannot see wlroots-0.20 under $prefix"

log "done: wlroots $(pkg-config --modversion wlroots-0.20)"
printf '\nNext:\n    cd %s && scons target=template_debug\n' "$here"
