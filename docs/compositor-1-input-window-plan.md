# Implementation plan — Compositor 1: interactive Wayland window in the launcher

- **Status:** Draft
- **Predecessor:** Compositor 0 (`docs/wayland-surfaces-phase-0.md`) — one-way display proven.
- **Target:** Godot 4.5, OpenXR, arm64 Linux on the RB 5.
- **Core branch:** `feat/compositor-1-input`, cut from `spike/xr-compositor-poc` (#27),
  contains Milestones 1, 2 and 4 (bridge seat, translation, keyboard) — nothing that
  touches `HandPointer` or `SWindow`.
- **Integration branch:** `feat/compositor-1-swindow`, cut from
  `feat/spatial-window-layout` (#28); merge the completed core branch, then add Milestones
  3 and 5. Both edit files (`HandPointer`, `SWindow`) that #28 is itself changing, so they
  land here against #28's versions rather than fighting a merge conflict later.

## Context

Compositor 0 proved one direction: a single `wl_shm` client's pixels reach a fixed quad,
converted correctly, at a cheap per-frame CPU cost. It deliberately implemented **no
input**, no resize, no popups, and **no `SWindow` integration** — the surface is a bare
`MeshInstance3D`, not a launcher window.

Compositor 1 makes that surface **interactive and native**: the user points, clicks and
types into a real Wayland client, and that client lives inside an `SWindow` so it inherits
focus and slot placement. When windowing Phase 1 is present, it also inherits solo-mode
suspension and input gating. This is the prerequisite for every interactive external app
on the roadmap (terminal, editor, and eventually a browser); "internet access" is not a
compositor concern — a launched client already has the network.

The compositor is proven with a **lightweight interactive client** (`weston-terminal`),
**not a browser**. A browser needs popups/subsurfaces (Compositor 2) and dmabuf GPU
buffers (Compositor 3), both out of scope here.

### Dependency and delivery split

Milestones 1, 2 and 4 — bridge seat, translation, keyboard — depend only on the
Compositor 0 spike (#27) and stay on `feat/compositor-1-input`. They add C API, a
GDScript translation node and keyboard routing, and touch neither `HandPointer` nor
`SWindow`, so they do not wait on window-layout work.

Milestones 3 and 5 are real integration dependencies and land separately. Milestone 3
extends `HandPointer`; Milestone 5 rewrites `SWindow` — both files `feat/spatial-window-layout`
(#28) is itself changing, so building them on the core branch would only re-fight the same
edits as a merge conflict later. Create the integration branch from #28, merge the
completed core input branch, and implement Milestones 3 and 5 there against #28's versions.
The branch relationship is:

```text
#27 Compositor 0 ── core branch (M1, M2, M4) ──┐
                                                     ├── integration branch ── M3, M5
#28 Windowing Phase 0 ─────────────────────────────┘
#29 Windowing Phase 1 ── optional compatibility test only
```

This gives the integration commit both required histories instead of testing an
uncommitted local merge:

- Windowing Phase 0 supplies manager-owned transforms, focus routing, and the three slots.
  #28 also carries the `HandPointer` hover baseline — XR `ENTERED`/`EXITED` and a reliable
  `RELEASED`, but not yet the unpressed hover `MOVED` — that Milestone 3 completes.
- Windowing Phase 1 supplies the solo/suspension input gate when present. It is additive:
  the adapter uses the ordinary Phase-0 focus gate otherwise and does not require #29 to
  land.

Windowing Phase F and Phase 0 are already built on `feat/spatial-window-layout`. Test an
additional local composition with `feat/spatial-window-layout-phase1` to verify that its
gate is reused, but keep #29 out of the integration branch ancestry. Nothing here needs a
future windowing phase (taskbar/stashing or slot reordering). If #28 reaches `main` first,
base the integration branch on that updated `main` instead. Once the core branch and #28
have landed, rebase the integration branch onto `main`; its review diff then contains M3 and
M5 only.

## Scope

**In:** a `wl_seat` with pointer + keyboard on the bridge; Godot→Wayland coordinate and
keycode translation; completing the custom `HandPointer` hover lifecycle and translating
it plus virtual/USB keyboard input for the focused surface; an `SWindow` content-surface
adapter so a window can present a compositor texture; surface configured to its slot size
before its first buffer maps.

**Out (later phases):** interactive resize negotiation and popups/subsurfaces
(Compositor 2); dmabuf / zero-copy GPU buffers (Compositor 3); multiple simultaneous
clients; scroll/axis input (no XR gesture produces it yet); clipboard and drag-and-drop;
client-set cursor rendering; `xdg-activation-v1` focus tokens; XWayland; browser validation.

## Key files

- `native/bridge/wl_bridge.{c,h}` — add the `wl_seat`; additive C API only.
- `native/src/wayland_compositor.{cpp,h}` — expose input methods to GDScript;
  Godot→evdev keycode mapping.
- `project/compositor/compositor_poc.gd` — drive input on the bare quad (keyboard, M4, on
  the core branch; pointer routing, M3, on the integration branch).
- `project/compositor/compositor_screen.tscn` — pointable POC collider/surface.
- `project/interaction/hand_pointer.gd` — emit a complete hover and pinch event lifecycle.
- `project/compositor/wayland_pointer_router.gd` — select one hand as the Wayland pointer.
- `project/windowing/{swindow.gd,window.tscn,window_manager.gd}` — content-surface
  adapter and fixed-size compositor-window policy (Milestone 5, integration branch).
- `native/tests/`, `tests/` — C input client and GDScript mapping/gating tests.

The bridge stays the only place wlroots types exist, and every call stays on Godot's main
thread (the Compositor 0 threading contract is unchanged: `wl_shm` access is not thread-safe).

---

## 1. `wl_seat` on the bridge (`wl_bridge.c`)

Add a `wlr_seat` advertising **pointer + keyboard** capabilities, and an xkb keymap sent
to the client over `wl_keyboard.keymap` (build it with `xkbcommon`; a malformed keymap fd
crashes the client, so validate it). Send `wl_keyboard.repeat_info` with the keymap so the
client owns key repeat; the bridge then forwards only real press/release edges, never
synthetic repeats. Mapping a surface does not focus it. Pointer focus
follows the pointer enter/exit stream; keyboard focus and the `xdg_toplevel` activated
configure state follow `SWindow` focus. Unmap/gone clears both defensively.

Additive C API (surface-local coordinates in pixels; the caller passes plain data and
never handles wlroots types):

```c
void wlb_pointer_enter(wlb_server *s, double sx, double sy);
void wlb_pointer_motion(wlb_server *s, double sx, double sy);
void wlb_pointer_leave(wlb_server *s);
void wlb_pointer_button(wlb_server *s, uint32_t button, int pressed);
void wlb_keyboard_key(wlb_server *s, uint32_t keycode, int pressed);
void wlb_keyboard_focus(wlb_server *s, int focused);
void wlb_toplevel_set_activated(wlb_server *s, int activated);
void wlb_set_initial_size(wlb_server *s, uint32_t width, uint32_t height);
```

Each pointer API call is one complete logical batch. After sending the call's events, the
bridge emits exactly one `wlr_seat_pointer_notify_frame()`; GDScript never sends a frame
explicitly. Scroll/axis is out of C1: no hand-tracking gesture produces scroll yet, and
`weston-terminal` interactivity is proven by click and type. When a scroll producer is
chosen (a controller axis or a dedicated XR gesture), add the axis with
`WL_POINTER_AXIS_SOURCE_CONTINUOUS`, which fits a synthetic source and needs no `axis_stop`
— not `WL_POINTER_AXIS_SOURCE_FINGER`, whose finger-up requires an `axis_stop` this API
would have to grow.

The bridge uses one `CLOCK_MONOTONIC` timestamp source shared by pointer and keyboard
events, and owns the xkb state. A key event updates that state and sends any resulting
modifier event; GDScript does not calculate xkb masks.

**Verifiable off the board (Linux arm64):** `weston-terminal` receives motion/click
(text selection moves) and keystrokes (they echo). Risk: `weston-terminal` may bind
globals Compositor 0 does not serve (`wl_output`, `wl_data_device_manager`). Serve minimal
stubs, or fall back to a tiny purpose-built client in `native/tests` if a stub is more
work than it earns.

## 2. Godot → Wayland translation (`wayland_compositor.cpp`)

Expose input to GDScript on the node, converting at the boundary:

```
pointer_enter(Vector2 uv)       # normalized surface UV -> surface-local pixels
pointer_motion(Vector2 uv)
pointer_leave()
send_button(button, pressed)
send_physical_key(InputEventKey event)
send_virtual_key(InputEventKey event)
set_keyboard_focus(focused)
set_toplevel_activated(activated)
set_initial_size(Vector2i size)
```

Map physical Godot keys → **Linux evdev keycodes** (xkb = evdev + 8), preserving
press/release and key location and ignoring Godot-generated echo events because Wayland
clients implement repeat from the advertised repeat information. The virtual keyboard
publishes one pressed `InputEventKey` per tap even though its visual button later receives
a release; expand that event into the required modifier chord, key press/release, and
modifier release. Drive the mapping from tables and unit-test it (see Tests, below).
Accept surfaces at scale 1 and normal transform only, matching Compositor 0.

## 3. Complete and route the custom XR pointer (`compositor_poc.gd`) — integration branch

Give the POC quad a pointable collider. Building on #28's `HandPointer` — which already
emits XR `ENTERED`/`EXITED` and a reliable `RELEASED` but still only sends `MOVED` while
pinching — add the missing **unpressed hover `MOVED`** so the full lifecycle is `ENTERED`,
hover `MOVED`, `PRESSED`, drag `MOVED`, `RELEASED`, `EXITED`. Hover motion is new
shared-interaction work rather than an existing stream the compositor can merely translate,
and it also closes the pre-existing hover gap for today's `SubViewport` windows.

Position sources differ by phase, matching Wayland's pointer model:

- **Unpressed hover** uses the raycast **collision point**. The raycast hit/miss is the
  natural `ENTERED`/`EXITED` edge, and leaving the collider means the pointer left the
  surface — a `pointer_leave`, not a coordinate.
- **Press through release** uses the locked target's **live facing plane**
  (`_locked_plane_hit`). Wayland holds an implicit grab from button-down until release:
  motion and the release keep going to the pressed surface even when the ray leaves it,
  with surface-local coordinates that may fall outside `[0, size]`. The plane supplies that
  continuous off-collider coordinate — the collision point no longer exists once the ray
  clears the collider. Do **not** emit a leave mid-press.
- **After release**, emit `pointer_leave` if the ray is then outside the collider.

`tests/collision_zorder_parity_test.gd` is what makes the hover→grab handoff safe: at the
press instant the ray is on the collider, where the collision point and the live-plane
intersection are the same point and resolve to the same z-order, so switching the position
source at button-down is seamless. The test proves only this on-collider agreement; it does
not exercise the off-surface grab path or the plane's live-depth tracking. Header drag and
resize already resolve against the live plane throughout their gesture, so a grab that keeps
using the plane stays consistent with them.

The two-source split is deliberate, not an oversight to simplify later: the on-collider
parity does **not** make the plane redundant, because only the plane yields the off-collider
coordinate the implicit grab requires, and the raycast the collision point comes from is
already needed to select the target. Do not collapse hover and grab onto one source —
`tests/collision_zorder_parity_test.gd` carries the same warning, and the rationale should
be repeated in `_locked_plane_hit`'s doc comment when Milestone 3 edits it.

Add a small compositor `WaylandPointerRouter` that reduces the two `HandPointer` streams
to Wayland's single pointer. The first hovering hand is the default owner; a non-owner
press can claim ownership only while the current owner is not pressed; once pressed, the
owner is retained through release; an unpressed owner that exits yields to the next
hovering hand. Use XR Tools' `viewport_2d_in_3d_body.gd` as a behavioural reference, not as
reusable code: its policy is private to the viewport and its pressed-pointer switch is
keyed on `XRToolsFunctionPointer`, which `HandPointer` is not. The router then translates
the selected hand's lifecycle to pointer enter/motion/button/leave; pinch maps to
`BTN_LEFT`. On an ownership handoff it must send `pointer_motion` (or enter) at the new
owner's coordinates **before** its button-down: a Wayland button carries no location and
uses the last enter/motion, so without the leading motion the claiming hand's click lands
where the previous owner was. Prove the loop on the quad before any `SWindow` work.

Off the board (no OpenXR runtime there) drive this through the mouse/simulated-pointer path
and the coordinate unit tests; true in-headset pointing is confirmed on the board (see
Verification split, below).

## 4. Keyboard routing (`compositor_poc.gd`)

Route key events for the focused surface from both a USB keyboard and
`XRToolsVirtualKeyboard2D`. Physical events preserve their press/release state. Virtual
events use `send_virtual_key`, which synthesizes the release and any modifier chord at the
Wayland boundary without changing how existing `SubViewport` windows consume the keyboard.
(A separate, out-of-scope limitation: `XRToolsVirtualKeyboard2D` has no Tab key, so a
hands-only user cannot Tab between fields; that fix belongs in the virtual keyboard, not
here.)

## 5. `SWindow` content-surface adapter — integration branch

Today `SWindow` content is an `XRToolsViewport2DIn3D` driving a `SubViewport` that hosts a
`PackedScene`; input arrives as `InputEvent`s pushed into that viewport, while `SWindow`
focuses itself from the content surface's `pointer_event`. A compositor client is neither
a scene nor a viewport — it is an external texture plus a seat.

Introduce a **content-surface abstraction** so an `SWindow` can be backed by *either* a
`SubViewport` scene *or* a compositor surface:

- present `compositor.get_texture()` where the viewport texture would sit;
- consume the normalized output of the Milestone-3 pointer router and the existing
  `SWindow` key/focus route, translating only at the content-surface boundary;
- forward `SWindow` focus to keyboard focus and the `xdg_toplevel` activated state;
- make `SWindow.set_input_enabled` gate compositor seat delivery as well as the existing
  `SubViewport` path. Phase 1's suspension/transition path reuses that call when present;
  no Phase-1 API is required;
- assign the slot and its fixed pixel size before launching the client, so the bridge sends
  that size in the initial `xdg_toplevel` configure before the first buffer maps;
- mark compositor-backed windows non-resizable. Their resize handles stay hidden and
  disabled for their lifetime, and programmatic resize requests are ignored. When Phase 1
  is present, solo mode centres the window and suspends its siblings without changing the
  compositor window's mapped content size. Compositor 2 adds configure-on-resize and
  re-enables resizing.

The integration branch uses *windowing Phase 0*, which already contains Phase F. Keep the
compositor behaviour behind the content-surface abstraction so the `SubViewport` path is
unchanged. Phase 1 is a compatibility check, not a merge or landing dependency, and
nothing here needs a future windowing phase.

## 6. Board-only (deferred to the physical RB 5)

End-to-end input latency in-headset, and frame pacing re-confirmed with a live interactive
client (heavier than `weston-simple-shm`). The board returns ~2026-09-21; these are the
only items that must wait for it.

---

## Commit sequence

Core branch (`feat/compositor-1-input`) — no `HandPointer`/`SWindow` changes:

1. **M1:** `feat(compositor): add wl_seat with pointer and keyboard to the bridge` (+ C
   input client test, including focus enter/leave and `repeat_info`).
2. **M2:** `feat(compositor): translate Godot input to Wayland seat events` (+ keycode/UV
   unit tests).
3. **M4:** `feat(compositor): route keyboard and virtual-keyboard input to the surface`.

Integration branch (#28 plus the merged core branch), built against #28's `HandPointer`
and `SWindow`:

4. **M3**, as two reviewable commits:
   - `feat(interaction): add the unpressed hover MOVED to complete the HandPointer lifecycle`;
   - `feat(compositor): arbitrate hand pointers and drive the POC surface`.
5. **M5:** `feat(windowing): back an SWindow with a fixed-size compositor surface`.

## Tests

- **C, against real wlroots 0.20.2** (on Linux arm64, off the board): a client binds
  `wl_seat` and asserts it receives pointer enter/motion/button/leave, keyboard
  enter/key/modifier/leave, the advertised `repeat_info`, one pointer frame per API batch,
  the requested initial configure, and `xdg_toplevel` activated-state changes after the
  bridge is driven. Proves Milestone 1 without a GUI.
- **GDExtension integration, Linux arm64:** drive `WaylandCompositor` methods and observe
  the C client, proving UV and physical/virtual-key translation across the real boundary.
- **GDScript, headless (integration branch):** `HandPointer` emits ordered
  enter/hover/press/drag/release/exit events using the collision point for unpressed hover
  and the live locked-target plane from press through release, with
  `tests/collision_zorder_parity_test.gd` guarding that the two agree at the press handoff
  (same point and z-order on the collider); a pressed grab keeps delivering motion after the
  ray leaves the collider and emits no leave until release; two-hand routing retains a
  pressed owner and sends motion at the new owner's coordinates before its button on a
  handoff; compositor windows expose no resize handles and ignore programmatic resize
  requests.
- **Additional Phase-1 compatibility composition:** suspended or mid-tween windows deliver
  no pointer or keyboard input, and a compositor window remains fixed-size through a solo
  cycle. This verifies reuse of #29's gate without making #29 a landing dependency.
- **Manual, on Linux arm64 (off the board):** `weston-terminal` — click to move the
  selection and type to echo.
- **Manual, on the board:** the Milestone 6 latency and pacing checks.

Every headless run uses `--xr-mode off` (a modal OpenXR alert otherwise blocks it).

## Verification split

Off the board (Linux arm64) proves **correctness** — events are delivered, focus is right,
and `weston-terminal` responds. The optional Phase-1 composition separately verifies its
input gate. The RB 5 proves **latency and interactive pacing**. Do not claim in-headset
input, hand tracking, or frame cost was verified until it runs on the board.

## Risks

| Risk | Response |
|---|---|
| xkb keymap fd malformed → client crashes on focus | Build with `xkbcommon`; validate against `weston-terminal` early. |
| Godot keycodes ≠ evdev keycodes | Separate physical and virtual translation; explicit tables + integration tests; remember xkb = evdev + 8. |
| A virtual key has no public release event | Synthesize its modifier/key release sequence at the Wayland adapter boundary. |
| Completing `HandPointer` hover changes the shared interaction stream | Keep the standard event order explicit and regression-test both `SubViewport` and compositor consumers. |
| Wrong coordinate mid-drag, or two-hand ownership diverges | Collision point for hover, live locked-target plane for the press-to-release grab (agreement parity-tested at the handoff); on a handoff send motion before button; unit-test the router's press-to-release ownership. |
| Scroll has no XR producer in C1 | Defer axis input; when a producer exists, add `WL_POINTER_AXIS_SOURCE_CONTINUOUS` (no `axis_stop` needed). |
| Test client binds globals we don't serve | Stub minimal `wl_output`/`wl_data_device_manager`, else a tiny custom client. |
| `SWindow` input path assumes a `SubViewport` | Content-surface abstraction; leave the viewport path untouched; Milestone 5 last. |
| Layout resizes a compositor-backed window before Compositor 2 can renegotiate its buffer | Mark it non-resizable, keep handles disabled, and ignore programmatic resize requests. |
| Client-set cursor ignored | Acceptable for C1 (hide/ignore `wl_pointer.set_cursor`); revisit with popups. |
| Milestones 3 and 5 touch files #28 also changes | Land core input (M1/M2/M4) separately; implement M3 and M5 on the #28 integration branch that merges the core branch. |

## Definition of done

- `weston-terminal` is pointer- and keyboard-interactive off the board (Linux arm64), with
  correct focus, hover motion, click/drag, and typing;
- input mapping (UV→pixel, key→evdev) is unit-tested and the C seat test passes against
  real wlroots;
- a compositor-backed `SWindow` places and focuses like a normal window (Milestone 5), with
  the `SubViewport` path unchanged, no resize controls, and a fixed mapped size;
- start/stop leaves no leaked child, socket, or stale focus;
- in-headset latency and interactive pacing are recorded on the RB 5 (Milestone 6).

## Explicitly deferred

Interactive resize negotiation, scroll/axis input (no XR producer yet, and
discrete/value120 wheel fidelity later), popups/subsurfaces, dmabuf, multiple windows,
clipboard, drag-and-drop, client cursors, XWayland, and browser validation.
