# Implementation plan — Compositor 1: interactive Wayland window in the launcher

- **Status:** Draft
- **Predecessor:** Phase 0 (`docs/wayland-surfaces-phase-0.md`) — one-way display proven.
- **Target:** Godot 4.5, OpenXR, arm64 Linux on the RB 5.
- **Branch:** `feat/compositor-1-input`, cut from `spike/xr-compositor-poc` (#27).

## Context

Phase 0 proved one direction: a single `wl_shm` client's pixels reach a fixed quad,
converted correctly, at a cheap per-frame CPU cost. It deliberately implemented **no
input**, no resize, no popups, and **no `SWindow` integration** — the surface is a bare
`MeshInstance3D`, not a launcher window.

Compositor 1 makes that surface **interactive and native**: the user points, clicks and
types into a real Wayland client, and that client lives inside an `SWindow` so it inherits
focus, slot placement and solo mode. This is the prerequisite for every interactive
external app on the roadmap (terminal, editor, and eventually a browser); "internet
access" is not a compositor concern — a launched client already has the network.

The compositor is proven with a **lightweight interactive client** (`weston-terminal`),
**not a browser**. A browser needs popups/subsurfaces (Compositor 2) and dmabuf GPU
buffers (Compositor 3), both out of scope here.

### This work does not depend on the windowing effort

Compositor 1 introduces **no dependency on future windowing work**. Milestones 1–4 (below)
— bridge seat, translation, ray pointer, keyboard — depend only on the Phase-0 spike
(#27) and need nothing from the window-layout code at all. Only the final slice,
Milestone 5 (below), touches windowing, and even it depends only on **already-built**
window-layout work:

- Its **floor is windowing Phase 0 (tangent arc slots)**, which includes *windowing Phase F
  (foundation)*: transform ownership (`WindowManager` as the sole transform writer), the
  focus-routing split, and three-slot placement. With just these, a compositor-backed window
  can be placed, transformed, and focused like a normal window.
- It additionally **reuses the *windowing Phase 1 (solo mode)* input gate** — a suspended
  sibling or a window mid-solo-tween delivers no input — *when that is present*. This is an
  enhancement, not part of the floor: the adapter can land against *windowing Phase 0* and
  pick up the gate once *windowing Phase 1* is in.

All three windowing phases (F, 0, 1) are already built and stacked on `feat/spatial-window-layout-phase1`
(#29), so one local merge of #29 supplies everything Milestone 5 needs. Nothing here waits on
any **future** windowing phase (taskbar/stashing, slot reordering).

Rooting this branch at the spike (rather than on top of the window-layout branch) keeps it
a **sibling** of that stack rather than a fourth floor on it: it is one merge (#27→`main`)
from a clean base and never waits on the window-layout PRs (#28, #29). Build and test
Milestone 5 against a *local* merge of the *windowing Phase 1: solo mode* branch, without
putting that branch onto this one.

## Scope

**In:** a `wl_seat` with pointer + keyboard on the bridge; Godot→Wayland coordinate and
keycode translation; XR-ray pointer and virtual/USB keyboard routing to the focused
surface; an `SWindow` content-surface adapter so a window can be backed by a compositor
client instead of a `SubViewport`; surface sized to its slot at map time.

**Out (later phases):** interactive resize negotiation and popups/subsurfaces
(Compositor 2); dmabuf / zero-copy GPU buffers (Compositor 3); multiple simultaneous
clients; clipboard and drag-and-drop; client-set cursor rendering; XWayland; browser
validation.

## Key files

- `native/bridge/wl_bridge.{c,h}` — add the `wl_seat`; additive C API only.
- `native/src/wayland_compositor.{cpp,h}` — expose input methods to GDScript;
  Godot→evdev keycode mapping.
- `project/compositor/compositor_poc.gd` — drive input on the bare quad (Milestones 1–4).
- `project/interaction/hand_pointer.gd` — source of the XR ray hit used for Milestone 3.
- `project/windowing/swindow.gd` — content-surface adapter (Milestone 5, below).
- `native/tests/`, `tests/` — C input client and GDScript mapping/gating tests.

The bridge stays the only place wlroots types exist, and every call stays on Godot's main
thread (the Phase-0 threading contract is unchanged: `wl_shm` access is not thread-safe).

---

## 1. `wl_seat` on the bridge (`wl_bridge.c`)

Add a `wlr_seat` advertising **pointer + keyboard** capabilities, and an xkb keymap sent
to the client over `wl_keyboard.keymap` (build it with `xkbcommon`; a malformed keymap fd
crashes the client, so validate it). Give the mapped `xdg_toplevel` pointer and keyboard
focus (`wlr_seat_pointer_notify_enter`, `wlr_seat_keyboard_notify_enter`) on map, and
clear it on unmap/gone.

Additive C API (surface-local coordinates in pixels; the caller has no `wlr_surface`, so,
as with frames, it passes plain data):

```c
void wlb_pointer_motion(wlb_server *s, double sx, double sy);
void wlb_pointer_button(wlb_server *s, uint32_t button, int pressed); /* linux/input BTN_* */
void wlb_pointer_axis(wlb_server *s, double dx, double dy);
void wlb_pointer_frame(wlb_server *s);                 /* group per input batch */
void wlb_keyboard_key(wlb_server *s, uint32_t keycode, int pressed);  /* evdev keycode */
void wlb_keyboard_modifiers(wlb_server *s, uint32_t depressed,
                            uint32_t latched, uint32_t locked, uint32_t group);
```

**Verifiable off the board (Linux arm64):** `weston-terminal` receives motion/click (text selection moves)
and keystrokes (they echo). Risk: `weston-terminal` may bind globals Phase 0 does not
serve (`wl_output`, `wl_data_device_manager`). Serve minimal stubs, or fall back to a tiny
purpose-built client in `native/tests` if a stub is more work than it earns.

## 2. Godot → Wayland translation (`wayland_compositor.cpp`)

Expose input to GDScript on the node, converting at the boundary:

```
send_pointer(Vector2 uv, ...)   # normalized [0,1] surface UV -> pixels via get_surface_size()
send_button(button, pressed)
send_scroll(Vector2 delta)
send_key(Key godot_key, pressed)
```

Map Godot keycodes → **Linux evdev keycodes** (xkb = evdev + 8). This is the classic
gotcha; drive it from a table and unit-test it (see Tests, below). Accept surfaces at
scale 1 and normal transform only, matching Phase 0.

## 3. Pointer from the XR ray (`compositor_poc.gd`, bare quad)

Convert the hand ray's hit on the quad to surface UV and call `send_pointer`; pinch maps
to `BTN_LEFT`. Reuse the same ray→plane→UV math the XR Tools 2D-in-3D viewport uses so the
mapping is consistent with the rest of the launcher. Prove the loop on the quad before any
`SWindow` work.

Off the board (no OpenXR runtime there) drive this through the mouse/simulated-pointer path
and the coordinate unit tests; true in-headset pointing is confirmed on the board (see
Verification split, below).

## 4. Keyboard routing (`compositor_poc.gd`)

Route key events for the focused surface to `send_key`, from both a USB keyboard and
`XRToolsVirtualKeyboard2D`. (A separate, out-of-scope limitation: `XRToolsVirtualKeyboard2D`
has no Tab key, so a hands-only user cannot Tab between fields; that fix belongs in the
virtual keyboard, not here.)

## 5. `SWindow` content-surface adapter (`swindow.gd`) — last; floor is windowing Phase 0

Today `SWindow` content is an `XRToolsViewport2DIn3D` driving a `SubViewport` that hosts a
`PackedScene`; input arrives as `InputEvent`s pushed into that viewport, and
`window_body.gd` focuses the window on a pointer press. A compositor client is neither a
scene nor a viewport — it is an external texture plus a seat.

Introduce a **content-surface abstraction** so an `SWindow` can be backed by *either* a
`SubViewport` scene *or* a compositor surface:

- present `compositor.get_texture()` where the viewport texture would sit;
- translate the window's existing pointer/focus/key routing into seat calls
  (Milestones 2–4, above) instead of `SubViewport` `InputEvent`s;
- size the surface to the assigned slot at map time via `xdg_toplevel` configure. Note that
  *windowing Phase 0 (tangent arc slots)* makes docked windows **user-resizable** (symmetric
  about the centre), but a compositor-backed window cannot renegotiate its buffer until
  Compositor 2. So the adapter must **suppress the resize handles on a compositor-backed
  window** (or accept a stretched buffer) until Compositor 2 adds configure-on-resize.
  **Interactive** resize negotiation is Compositor 2;
- **when *windowing Phase 1 (solo mode)* is present,** reuse its input gate: a **suspended**
  sibling or a window mid-solo-tween delivers no input. This is additive — the adapter still
  places and focuses correctly on *windowing Phase 0* alone.

The **floor** for this slice is *windowing Phase 0 (tangent arc slots)*, which subsumes
*windowing Phase F (foundation)*: `WindowManager` as the sole transform writer (windowing
Phase F), the focus-routing split (windowing Phase F), and three-slot placement (windowing
Phase 0). The suspend / solo-tween
input gate comes from *windowing Phase 1 (solo mode)* and is reused when present, not required
to land the adapter. Nothing here needs any **future** windowing phase. Keep it behind the
abstraction so the `SubViewport` path is untouched, and keep it the final commits so
Milestones 1–4 (above) land independently of the window-layout stack.

## 6. Board-only (deferred to the physical RB 5)

End-to-end input latency in-headset, and frame pacing re-confirmed with a live interactive
client (heavier than `weston-simple-shm`). The board returns ~2026-09-21; these are the
only items that must wait for it.

---

## Commit sequence

1. `feat(compositor): add wl_seat with pointer and keyboard to the bridge` (+ C input client test).
2. `feat(compositor): translate Godot input to Wayland seat events` (+ keycode/UV unit tests).
3. `feat(compositor): drive surface pointer from the XR ray on the POC quad`.
4. `feat(compositor): route keyboard and virtual-keyboard input to the surface`.
5. `feat(windowing): back an SWindow with a compositor surface` (Milestone 5; build on a
   local merge of the *windowing Phase 1: solo mode* branch).

## Tests

- **C, against real wlroots 0.20.2** (on Linux arm64, off the board): a client binds
  `wl_seat` and asserts it receives motion, button, axis, key and modifier events after the
  bridge is driven. Proves Milestones 1–2 without a GUI.
- **GDScript, headless:** UV→pixel and Godot-key→evdev mapping tables; input-gating —
  suspended/mid-tween windows deliver nothing (reuse the windowing fixtures).
- **Manual, on Linux arm64 (off the board):** `weston-terminal` — click to move the
  selection, type to echo, scroll.
- **Manual, on the board:** the Milestone 6 latency and pacing checks.

Every headless run uses `--xr-mode off` (a modal OpenXR alert otherwise blocks it).

## Verification split

Off the board (Linux arm64) proves **correctness** — events are delivered, focus and gating
are right, `weston-terminal` responds. The RB 5 proves **latency and interactive pacing**.
Do not claim in-headset input, hand tracking, or frame cost was verified until it runs on
the board.

## Risks

| Risk | Response |
|---|---|
| xkb keymap fd malformed → client crashes on focus | Build with `xkbcommon`; validate against `weston-terminal` early. |
| Godot keycodes ≠ evdev keycodes | Explicit table + unit test; remember xkb = evdev + 8. |
| Pointer coordinate mapping off (scale/aspect/transform) | Reuse XR Tools ray→UV math; scale-1 only; unit test. |
| Test client binds globals we don't serve | Stub minimal `wl_output`/`wl_data_device_manager`, else a tiny custom client. |
| `SWindow` input path assumes a `SubViewport` | Content-surface abstraction; leave the viewport path untouched; Milestone 5 last. |
| Layout resizes a compositor-backed window before Compositor 2 can renegotiate its buffer | Suppress resize handles on compositor-backed windows (or accept a stretched buffer) until Compositor 2 adds configure-on-resize. |
| Client-set cursor ignored | Acceptable for C1 (hide/ignore `wl_pointer.set_cursor`); revisit with popups. |
| Milestone 5 entangles with the stuck window-layout stack | Build it on a local merge of the *windowing Phase 1: solo mode* branch; keep that branch off this one. |

## Definition of done

- `weston-terminal` is pointer- and keyboard-interactive off the board (Linux arm64), with
  correct focus and input-gating for suspended/soloed windows;
- input mapping (UV→pixel, key→evdev) is unit-tested and the C seat test passes against
  real wlroots;
- a compositor-backed `SWindow` places and focuses like a normal window (Milestone 5), with
  the `SubViewport` path unchanged;
- start/stop leaves no leaked child, socket, or stale focus;
- in-headset latency and interactive pacing are recorded on the RB 5 (Milestone 6).

## Explicitly deferred

Interactive resize negotiation, popups/subsurfaces, dmabuf, multiple windows, clipboard,
drag-and-drop, client cursors, XWayland, and browser validation.
