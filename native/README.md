# Wayland compositor GDExtension

Native half of *Display one Wayland application in Godot*. Runs a
minimal Wayland server inside the launcher, copies one client's shared-memory
pixels into a Godot `ImageTexture`, and hands that texture to
`project/compositor/compositor_poc.gd`.

The architecture decision this implements is `docs/wayland-surfaces-phase-0.md`.

## Layout

| Path | What it is |
|---|---|
| `bridge/wl_bridge.{h,c}` | The only place wlroots types exist. Pure C. |
| `bridge/pixel_convert.{h,c}` | Row conversion. No wlroots, no Godot; builds and is tested anywhere. |
| `src/wayland_compositor.{h,cpp}` | The `WaylandCompositor` Godot node. |
| `src/register_types.cpp` | GDExtension entry point. |
| `tests/test_pixel_convert.c` | Conversion unit tests, plain `cc`. |
| `setup.sh` | Fetches and builds the pinned dependencies. |
| `godot-cpp/`, `.deps/` | Fetched and built by `setup.sh`. Both gitignored. |

`.gdignore` keeps Godot's importer out of this directory.

## Building

Linux arm64 only. wlroots does not exist on macOS, and the descriptor
deliberately declares no other target.

```bash
native/setup.sh && (cd native && scons target=template_debug)
```

Output lands in `project/compositor/bin/`, which the `.gdextension` descriptor
points at.

`setup.sh --force` discards every fetched tree and rebuilds from scratch.
Re-running it without `--force` is a no-op.

## Pinned versions

| Component | Pin |
|---|---|
| wlroots | `0.20.2` = `d783533489e1f75d6886c2ab5c5960090ef268f8` |
| godot-cpp | `godot-4.5-stable` = `e83fd0904c13356ed1d4c3d09f8bb9132bdc6b77` |

Tags move; the commits are the actual contract.

## The dependency chain, and why it exists

wlroots 0.20.2 is newer than what current stable distributions ship. On Debian
trixie every one of these is too old, so `setup.sh` builds them into
`.deps/prefix`:

| Dependency | wlroots needs | trixie ships | built at |
|---|---|---|---|
| wayland | >= 1.24.0 | 1.23.1 | `1.24.0` |
| wayland-protocols | >= 1.47 | 1.44 | `1.47` |
| libdrm | >= 2.4.129 | 2.4.124 | `libdrm-2.4.129` |
| libxkbcommon | >= 1.8.0 | 1.7.0 | `xkbcommon-1.8.1` |
| pixman | >= 0.46.0 | 0.44.0 | `pixman-0.46.4` |

Each is skipped when `pkg-config` already reports a new enough copy, so on a
newer host the script may build nothing but wlroots itself.

Pixman is on that list even though the compositor never renders: wlroots always
compiles its Pixman renderer, and `-Drenderers=` does not turn it off.

Host packages `setup.sh` expects to find already installed:

```bash
sudo apt install -y git meson ninja-build pkg-config scons build-essential \
    bison flex libffi-dev libexpat1-dev libxml2-dev libseat-dev hwdata weston
```

## Linking

wlroots **and every dependency `setup.sh` builds privately** are linked
statically, so deploying to the board is one `.so` rather than a `.so` plus a
private copy of six libraries. A dependency the system already satisfies is
skipped by `setup.sh` and stays an ordinary dynamic system library.

Linking wlroots alone statically is not enough, and fails in a way that looks
like success: the extension builds, but `libwayland-server.so.0` and friends
become `NEEDED` entries, the loader binds them to the system's *older* copies —
the very ones too old to build wlroots — and `dlopen` fails on the first symbol
that copy lacks. Observed exactly: `undefined symbol:
wl_resource_post_error_vargs`, which libwayland gained in 1.24.0 while Debian
trixie ships 1.23.1.

`scons` also relies on SCons emitting libraries **after** the object files. Feed
pkg-config through `env.ParseConfig`, which fills `LIBS`/`LIBPATH`; appending it
to `LINKFLAGS` places the archives before the objects that reference them, and
they contribute nothing. Same silent-success failure mode as above.

The resulting `.so` links against only `libffi.so.8`, `libm.so.6` and
`libc.so.6`. `libffi` is libwayland's dispatcher dependency and is expected to
be present on any image that runs Wayland at all; if the board's image predates
`libffi.so.8`, add libffi to the `DEPS` table in `setup.sh` and it will be
absorbed like the rest.

If static ever becomes impractical, the fallback is `-Wl,-rpath,$ORIGIN` (which
godot-cpp already sets) plus copying the transitive closure into
`project/compositor/bin/`. Record the switch here if it happens.

## Design notes worth knowing before editing

**No renderer.** `wlr_compositor_create(display, version, NULL)` — Godot does
the rendering. The consequence is that `wlr_surface->buffer` is always NULL,
because that field exists only to hold a renderer-built texture. Code copied
from renderer-ful examples reads NULL there and displays nothing.

**Lock the buffer inside the commit handler.** `surface_commit_state` unlocks
and NULLs `surface->current.buffer` immediately after emitting `commit`, on
purpose, so `wl_shm` buffers are released promptly. The lock the bridge takes in
its `surface.commit` listener is the only thing keeping those pixels alive long
enough to copy. Reading `current.buffer` later gets NULL.

**`wl_shm` must advertise both ARGB8888 and XRGB8888.** The protocol mandates
both, and `wlr_shm_create` asserts on a list missing either — advertising XRGB
alone is not an option. The bridge accepts both at acquire time and renders every
surface opaque: the converter forces alpha to `0xFF` and never blends, so the two
formats are byte-identical for opaque pixels. The known limit is that a genuinely
translucent client renders as opaque premultiplied — subtly dark on its
translucent pixels — which is why Cairo clients such as `weston-terminal` display
correctly (their windows are opaque). A frame on any other format is rejected at
acquire time with a rate-limited log.

**Frame callbacks go out on every path.** A client that never receives
`frame_done` stops drawing, so `wlb_frame_release` sends it whether the frame
was accepted or rejected.

**Process ownership is GDScript's.** The bridge never calls `waitpid`. See
`project/compositor/compositor_poc.gd`.

**Output scale is advertised two ways, and input stays logical.**
`wlb_set_output_scale` drives HiDPI so a client renders its buffer at `scale×`
(a legible terminal at distance). Legacy toolkits read it from `wl_output` — the
bridge sends `wl_output.scale` and a `wl_surface.enter` on map; modern
`wl_compositor` v6 clients read the per-surface `preferred_buffer_scale` the
bridge also sets on map and on change. Either way the buffer, and so the texture,
is `scale×` the surface, but pointer coordinates are surface-local (logical): the
bridge tracks `surface->current.width/height`, not `buffer_width/height`, so UV
input divides by the logical size. The frame path copies the full buffer
separately. Note the default harness client, `weston-simple-shm`, binds no
`wl_output` and sets no buffer scale, so it renders at 1× and does not exercise
this path; drive scale with `weston-terminal` (`WRL_COMPOSITOR_CLIENT`) instead.

## In the launcher

`project/compositor/compositor_screen.tscn` is the reusable half: a
`MeshInstance3D` carrying `compositor_poc.gd` and a 0.6 m quad. It runs in two
places:

| Where | How |
|---|---|
| The launcher | `WindowManager` opens it in the LEFT slot through `create_compositor_window()`, hosted by an `SWindow` |
| `project/compositor/compositor_poc.tscn` | Free-standing `Screen` at `(0, 1.2, -1)`, the local Linux harness |

Hosted, the window replaces its Content viewport with the screen and keeps the
layout default size for its lifetime: the quad is fixed at that size, the client
is asked for it in its first configure (at the window's pixel density), and the
window has no resize handles. A client that picks another size is stretched to
the quad. Window focus, suspension and the solo tween's interaction lock gate
the screen's pointer and keyboard input. Free-standing, the quad follows the
surface's aspect and a mapped surface takes focus by itself. Its `mesh` is
`resource_local_to_scene` either way, so one instance cannot resize another's.

Two independent rules keep it invisible where it cannot work: `visible = false`
is serialized into the scene rather than applied in `_ready`, and `visible`
becomes true only once `get_texture()` has returned a texture *and* it has been
bound. `ClassDB.class_exists("WaylandCompositor")` is the only gate — where the
class is absent `_ready` prints one line and returns, having already called
`set_process(false)`, and the launcher opens a placeholder window in LEFT
instead. That is an expected host, not a misconfigured one.

Every screen joins the `wayland_surfaces` group; `root.gd` shuts each one down
before quitting, and closing a compositor window waits for its client to exit.

## Testing

Conversion tests run everywhere, including macOS and x86_64 CI:

```bash
godot --headless --xr-mode off --path . --script res://tests/pixel_convert_check.gd
```

The scene and descriptor are checked the same way, and are specifically
verified to load on a host with no extension built:

```bash
godot --headless --xr-mode off --path . --script res://tests/compositor_scene_check.gd
```

`tests/compositor_extension_check.gd` asserts the pair the other way round — the
class is registered where a library exists for the host, and absent where none
does. It needs the project imported first, because Godot registers extensions
during import; without that it reports the class missing everywhere and proves
nothing:

```bash
godot --headless --xr-mode off --path . --import
godot --headless --xr-mode off --path . \
    --script res://tests/compositor_extension_check.gd
```

`tests/compositor_visibility_check.gd` covers the dormant path with the node in
the tree: hidden before and after `_ready`, no compositor child, no material,
processing off. Where the class *is* registered it skips rather than starting a
real server:

```bash
godot --headless --xr-mode off --path . \
    --script res://tests/compositor_visibility_check.gd
```

Neither suite can show that a real client's frames reach the quad. That needs
the extension, a display and a live server, and belongs to
`tests/linux/poc_capture.gd`.

Anything involving a live Wayland server needs Linux; those harnesses are
local-only and are not part of the tracked suites.

## Not done yet

Nothing here has run on the RB 5. The static-link decision and all frame-timing
numbers stay provisional until it does.
