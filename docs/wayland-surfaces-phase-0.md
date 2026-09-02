# Wayland applications as spatial windows: Phase 0 architecture decision

- **Status:** Provisional go
- **Follow-up:** `[Compositor 1] Display one Wayland application in Godot`
- **Target:** Godot 4.5, OpenXR, arm64 Linux on the RB 5
- **Last updated:** 2026-09-02

## Decision summary

Prototype with **wlroots 0.20.2**, pinned to its exact source commit and checksum
when the implementation begins. Keep wlroots behind a small **pure-C bridge**
linked into a Godot GDExtension. This prevents wlroots' version-dependent C
types and listener macros from spreading into the C++ Godot integration.

The first proof of concept will:

- run a minimal, in-process Wayland server with `wl_compositor`, `wl_shm`, and
  `xdg_wm_base`;
- accept one `xdg_toplevel` application window;
- copy its shared-memory pixels into one persistent Godot `ImageTexture`;
- display that texture on a fixed `MeshInstance3D` quad in the XR scene; and
- use `weston-simple-shm` as the first client.

This first proof of concept will not implement input, resizing, popups,
multiple windows, XWayland, GPU-buffer sharing, or integration with the
launcher's existing `SWindow` class. These are separate risks and do not need
to be solved to prove the surface-to-XR path.

## Why wlroots

wlroots supplies the Wayland protocol and surface lifecycle machinery that this
project needs without requiring a complete desktop environment. `tinywl` is a
useful reference for protocol setup, but it should not be copied and reduced:
this proof of concept needs only a display socket, shared-memory buffers, XDG
shell surfaces, and non-blocking event dispatch.

The selected wlroots version supports creating `wl_shm` without a renderer and
allows a compositor with no renderer. That matches this design because Godot,
not wlroots, performs the final rendering. If the pinned build unexpectedly
requires a renderer on the target, use the Pixman software renderer as a
fallback; do not add a second GLES or Vulkan context to the proof of concept.

Other options add work without reducing the main risk. Smithay adds a Rust/C++
boundary, capturing a nested compositor's whole output loses per-window surface
identity, and implementing the protocols directly with libwayland would
recreate lifecycle code that wlroots already provides.

## Surface and buffer path

```text
Wayland client
  -> wl_surface attach/commit
  -> wlroots exposes the committed wlr_buffer
  -> C bridge reads shared-memory pixels
  -> format/stride conversion into RGBA8
  -> persistent Godot ImageTexture update
  -> material on a fixed XR quad
```

The compositor and buffer copy run on Godot's main thread. Each Godot frame
polls the Wayland event loop with a zero timeout and flushes clients; it must
never wait for a Wayland event. wlroots documents shared-memory access as not
thread-safe, so moving this work to a worker thread is out of scope for this
proof of concept.

When a surface commits a buffer, the bridge must:

1. lock the buffer for the duration of the read;
2. begin read access and use the returned width, height, pixel format, and
   **stride** (the byte distance between rows);
3. advertise both `XRGB8888` and `ARGB8888` on `wl_shm` — the protocol
   mandates both, and `wlr_shm_create` asserts on a list missing either — but
   accept only `XRGB8888` frames, at scale 1 and normal transform, rejecting
   `ARGB8888` at acquire time because it is premultiplied;
4. convert the little-endian BGR byte layout to Godot's RGBA8 layout;
5. update one long-lived `ImageTexture`, recreating it only if dimensions
   change;
6. end access and unlock the buffer; and
7. complete the client's frame callback at most once per Godot frame, whether
   or not the frame was accepted — a client that stops receiving `frame_done`
   stops drawing.

Unsupported formats, transforms, scales, or roles must produce a clear log
message instead of an incorrectly rendered image. The server must also send the
initial XDG configure event; a conforming client normally waits for and
acknowledges this event before attaching its first buffer.

## Copy first; GPU sharing later

This proof of concept deliberately uses a CPU copy. `wl_shm` is the smallest
path that tests the important integration points: wlroots inside Godot, two
event loops, buffer lifetime, texture upload, and XR frame cost. It also works
without modifying Godot or creating another GPU rendering context.

Direct DMA-BUF sharing is deferred. A production-quality zero-copy path would
need all of the following to work together:

- matching DRM devices, formats, and modifiers between the client and Godot;
- the required Vulkan or EGL external-memory extensions;
- acquire synchronization before Godot samples the image;
- release synchronization before the client reuses it; and
- safe texture lifetime across Godot's render thread.

Stock Godot 4.5 does not provide a settled GDExtension path for requesting the
needed Vulkan device extensions at device creation. Zero-copy is therefore an
optimization spike after the copy path works, not a prerequisite for the proof
of concept.

## Input path for the following card

Input is not implemented in this proof of concept, but the boundary is defined
now so the display proof does not create a dead end.

For pointer input, Godot will map the controller or mouse ray hit into surface
pixel coordinates. The Wayland adapter will resolve the leaf surface at that
point and send seat events for enter, motion, button, frame, and leave. It must
use Wayland surface-local coordinates, event timestamps, and Linux button codes.
The launcher's existing ray-to-plane coordinate math can be reused, but the
custom hand-pointer path currently reports motion mainly during a pinch. It
must expose hover entry, exit, and motion—or the adapter must sample the ray
while hovered—before it can drive correct Wayland pointer focus.

For keyboard input, one adapter must combine both existing sources: physical
Godot key events and the virtual keyboard signal. It will translate Godot keys
to Linux evdev keycodes, maintain an xkb keymap and modifier state, and send
Wayland key and modifier events. The virtual keyboard currently emits presses
without releases, so the adapter must synthesize matching release events to
avoid keys becoming stuck in client applications.

## First client

Use **`weston-simple-shm`**. It draws a small animated shared-memory surface and
does not depend on a GUI toolkit, OpenGL, fonts, or D-Bus. This sharply limits
the cause of a failure to the Wayland handshake, buffer handling, or Godot
texture path. Pin or build this example with the development dependencies so
its presence on the target image is not assumed.

A toolkit application such as a GTK calculator is a later compatibility test.
At that point the server will probably need a synthetic `wl_output` describing
a fixed output size, scale 1, and normal transform. Firefox and Chromium are
later tests because they are likely to make DMA-BUF support important.

## Operational requirements

- Create or validate a private `XDG_RUNTIME_DIR`, choose a collision-free socket
  name such as `wayland-godot-<pid>`, restrict its permissions, and remove it on
  shutdown.
- Set `WAYLAND_DISPLAY` only for the launched test client, for example through
  `/usr/bin/env`. Do not change it globally inside the launcher, which would
  redirect every subsequently launched child.
- Build the GDExtension and native dependencies for arm64 at the start of Card
  1. A host-only build does not prove deployment on the RB 5.
- Keep all wlroots objects inside the C bridge and expose only a narrow C API
  for initialization, polling, frame access/release, and shutdown.
- Shut down clients and the Wayland display before releasing bridge-owned
  buffers and Godot textures. Verify that no client process or socket remains.

## Risks and go/no-go criteria

No known issue makes the approach unsuitable today, but the decision remains
provisional until it runs on the target device.

| Risk | Response |
|---|---|
| wlroots API and listener complexity | Isolate it in the pure-C bridge and pin the source version. |
| Wayland work stalls the XR frame | Use zero-timeout polling on the main thread and record frame timing. |
| Buffer reuse causes corruption | Respect access windows, locks, format, stride, and frame callbacks. |
| CPU copy/upload is too expensive | Record P50/P95/P99 copy-plus-upload time and missed XR frames on the RB 5. |
| Native dependencies do not deploy on arm64 | Prove the target build before implementing the full buffer path. |
| Existing `SWindow` assumes a `SubViewport` | Use a dedicated quad now; introduce a content-surface adapter in a separate follow-up. |

Proceed if the proof of concept renders the animated client correctly on both
the development host and RB 5, starts and shuts down repeatedly without leaks or
stale sockets, and does not cause material XR frame misses. A pass proves the
plumbing, not multi-window scalability: the tiny test surface is only an early
performance signal. Reconsider the architecture if the native extension cannot
be deployed reproducibly, non-blocking dispatch still causes repeated XR stalls,
or a representative-size copied surface cannot meet the launcher's frame budget.

## Implementation order and definition of done

1. Build a Godot GDExtension skeleton plus the C bridge for the host and arm64.
2. Start the private socket and advertise the three required Wayland globals.
3. Launch `weston-simple-shm` with a per-process `WAYLAND_DISPLAY` and complete
   the XDG configure handshake.
4. Read committed buffers, convert them, and update one persistent texture.
5. Display that texture on a fixed XR quad and send frame-done callbacks.
6. Instrument copy/upload time, missed XR frames, startup, and shutdown.

The proof of concept is complete when:

- the same pinned native source builds for the host and RB 5;
- the client animation has correct colors and geometry, with no frozen first
  frame or buffer-reuse corruption during a multi-minute run;
- unsupported buffer cases are rejected with useful logs;
- client and launcher shutdown leaves no crash, hang, child process, or stale
  socket; and
- P50, P95, and P99 copy-plus-upload time plus XR missed-frame count are
  recorded on the RB 5.

## Explicitly deferred

`SWindow` integration, pointer and keyboard implementation, resize negotiation,
multiple windows, popups and subsurfaces, damage-based partial updates,
clipboard and drag-and-drop, synthetic outputs for toolkit clients, DMA-BUF,
XWayland, and browser validation are outside Phase 0.

## References

- [wlroots 0.20.2 release](https://gitlab.freedesktop.org/wlroots/wlroots/-/releases/0.20.2)
- [wlroots shared-memory interface](https://wlroots.pages.freedesktop.org/wlroots/wlr/types/wlr_shm.h.html)
- [wlroots compositor and surface API](https://wlroots.pages.freedesktop.org/wlroots/wlr/types/wlr_compositor.h.html)
- [wlroots buffer access and lifetime API](https://wlroots.pages.freedesktop.org/wlroots/wlr/types/wlr_buffer.h.html)
- [wlroots XDG shell API](https://wlroots.pages.freedesktop.org/wlroots/wlr/types/wlr_xdg_shell.h.html)
- [wlroots seat input API](https://wlroots.pages.freedesktop.org/wlroots/wlr/types/wlr_seat.h.html)
- [Weston `simple-shm` client source](https://cgit.freedesktop.org/wayland/weston/tree/clients/simple-shm.c)
- [Godot 4.5 `RenderingServer`](https://docs.godotengine.org/en/4.5/classes/class_renderingserver.html)
- [Godot proposal: request rendering-device extensions](https://github.com/godotengine/godot-proposals/issues/13969)
