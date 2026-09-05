# Implementation plan — Spatial window layout, Phases F + 0

This document maps the spatial-window design onto the current windowing code.
Phases F and 0 ship together as one release unit.

## 1. Contracts and phase boundary

- There are three persistent slots: `LEFT`, `CENTRE`, and `RIGHT`.
- Focus changes input routing, MRU history, and header styling only. It never
  changes a slot or transform.
- `WindowManager` is the only owner of window transforms. A window owns its
  persistent `content_size` and internal geometry.
- A resize keeps the content centre fixed and grows symmetrically. This replaces
  the current opposite-edge-pinned interaction.
- Header dragging is disabled when the arc is enabled. Slot reordering returns
  in Phase 3.
- Phase 0 has at most three open windows. Stashing and solo presentation do not
  exist yet, although their state fields are introduced for the later phases.
- The application menu remains an ordinary window. There is no launcher
  full-screen mode.
- Phases F and 0 are one release unit. Do not create an intermediate checkpoint
  that removes the Z stack while windows still overlap on the old flat layout.

The parent design requires widths to be safe under every later slot permutation.
Phase 0 therefore constrains the two widest **open** windows, including stashed
windows once those exist. Phase 2 cycling and Phase 3 dragging can then move a
window into any slot without moving, resizing, or rejecting it.

## 2. Current code that changes

- `project/windowing/window_manager.gd` uses `windows_list` simultaneously for
  lifetime, focus, and Z order. `create_window()` accepts a free position.
- `project/windowing/swindow.gd` writes its own world position during drag and
  resize. Its resize plane and displacement assume world XY and an unrotated
  window.
- `project/windowing/window_manager.tscn` has no child anchors. The keyboard is
  instantiated directly under the manager at a hardcoded local pose.
- `project/main/root.tscn` uses `WindowFollow` to copy translation, but not
  rotation or scale, to `WindowManager`. No root-scene change is required.
- `project/interaction/hand_pointer.gd` locks a target through a pinch and sends
  `PRESSED`, `MOVED`, and `RELEASED`. Its public hover signals do not currently
  send `ENTERED` or `EXITED` to the collider.

Several tests rely on the old API, direct keyboard parenting, or unlimited test
window creation. They must change in the same commits as their contracts.

## 3. Target ownership and state

Use the existing `WindowManager` as the workspace anchor:

```text
WindowManager            workspace-local origin; moved by WindowFollow
├── WindowLayer          identity transform; all SWindow nodes live here
├── KeyboardAnchor       authored pose; keyboard instance is an identity child
└── Taskbar              Phase 2, not created now
```

Any unrelated manager child introduced by another feature remains a direct
child and is not assigned a slot. If `CompositorScreen` is present, move it clear
of the arc — for example `+6.0` m in Y — so it cannot overlap a slot; confirm the
move changes no test.

Add typed manager state:

```gdscript
enum Slot { LEFT, CENTRE, RIGHT }

var open_windows: Array[SWindow] = []
var slots: Array[SWindow] = [null, null, null]
var stashed_queue: Array[SWindow] = []
var focused_window: SWindow = null
var focus_history: Array[SWindow] = [] # index 0 is most recent
var soloed_window: SWindow = null
```

State invariants:

- Every valid `open_windows` entry occurs in exactly one slot or exactly once in
  `stashed_queue`.
- Every occupied slot and stash entry occurs exactly once in `open_windows`.
- No window occurs in both a slot and `stashed_queue`.
- `focused_window` is null iff no active slot is occupied; otherwise it is open
  and slotted. A stashed window cannot be focused.
- `focus_history` contains each open window at most once.

In normal Phase 0 operation, `stashed_queue` is empty and `soloed_window` is
null. A clamp test may construct a valid future-state fixture containing a
stashed open window because the parent explicitly requires the Phase 0 clamp to
account for it; no public stash behavior is implemented yet.

Give each managed `SWindow` an explicit manager reference during creation. Its
parent becomes `WindowLayer`, so code must not assume `get_parent()` is the
manager.

Centralize slot mutations in small manager helpers such as `_slot_of(win)`,
`_assign_slot(win, slot)`, and `_clear_slot(win)`. `_assign_slot` applies only
the target transform; none of these helpers reads or writes `content_size`. They
give later stash/reorder phases one state path without exposing those features
in Phase 0.

## 4. Phase F work

### F1. Add anchors without changing placement

Add `WindowLayer` and `KeyboardAnchor` to `window_manager.tscn` using built-in
nodes; do not invent scene UIDs. Author the current keyboard pose on
`KeyboardAnchor` (`position = (0, 0, -1)`, X rotation `-35°`) and instantiate the
keyboard at identity beneath it.

Store the keyboard instance on the manager. Hide it when there is no focused
window, show it when focus exists, and continue routing key signals through the
manager. Update tests that search only direct manager children to search beneath
`KeyboardAnchor`.

### F2. Centralize size mutation

Keep the existing `content_size` member; no rename. It is still seeded from the
authored `content_3d.screen_size` in `_ready()` as today.

Keep `_apply_size(committed, live)` as the sole writer of `content_size` and the
sole updater of quad, collider, header, handle, and render-target geometry. It
may retain the local numeric `MIN_CONTENT_SIZE`/`MAX_CONTENT_SIZE` clamp as a
defensive fallback for standalone windows.

All managed size requests, including the public `resize()` method and pointer
gestures, must pass through:

```gdscript
WindowManager.clamp_content_size(win, desired) -> Vector2
```

This prevents startup code or a future caller from bypassing the angular
invariant. `SWindow.resize(desired, live := false)` asks its assigned manager to
clamp, then calls `_apply_size`; an unmanaged standalone test window falls back
to the numeric clamp. On resize release, settle render-target resolution without
introducing a second size-write path.

### F3. Make resize rotation-safe and fixed-centre

At `start_resize()`:

1. Focus first.
2. Freeze the window's orthonormalized `global_transform`.
3. Build a frozen interaction plane: its normal is the window's normalized face
   normal (`basis.z`), and it passes through the selected handle collider's depth
   centre rather than the window origin.
4. Resolve and store the grab point by intersecting the pointer ray with that
   plane. Do not use the raw physics collision point: it sits on the collider
   surface and exists only for target selection and cursor rendering.
5. Cache unit world axes `basis.x`, `basis.y`, and the starting `content_size`.

Do not cache a start position; resizing never changes the window origin.

For each move:

```text
dx = (hit - start_hit) dot cached_x_axis
dy = (hit - start_hit) dot cached_y_axis

R:  dw = +2dx, dh = 0
L:  dw = -2dx, dh = 0
B:  dw = 0,    dh = -2dy
BR: dw = +2dx, dh = -2dy
BL: dw = -2dx, dh = -2dy
```

The factor of two is required: the grabbed edge follows the pointer while the
opposite edge moves by the same amount around the fixed centre. Send
`start_size + (dw, dh)` through `resize(..., true)`. Each move intersects that
same frozen plane — never the raw collision point. Delete all resize position
shift state and writes. If any non-gesture caller of `_get_plane()` remains, it
must likewise use the live transformed face normal.

Cache the manager's legal content-width cap when the gesture starts, as required
by the parent design, and use it throughout that gesture. To keep that cached
cap sound, allow only one managed resize gesture at a time: the manager tracks the
active resize owner and ignores a second handle press until release/cancel.
Opening, closing, stashing, or programmatic resizing another window must cancel
the active gesture before changing the set or widths. This resolves the
otherwise-undefined two-hand case where two gestures could cache mutually
incompatible caps and then violate the invariant.

### F4. Split focus and lifetime state

`focus(win)` must reject invalid, non-open, non-slotted, or suspended windows.
A *suspended* window is one hidden behind a solo presentation — every non-soloed
window while `soloed_window` is set. That cannot occur until solo mode arrives in
a later phase, so no Phase 0 window is suspended. Otherwise `focus(win)`:

1. Disables keyboard/gamepad input on the old focused window.
2. Removes `win` from `focus_history` and pushes it at index 0.
3. Assigns `focused_window`.
4. Enables input on `win`.
5. Updates focused-header styling and keyboard visibility.

It does not mutate `open_windows`, `slots`, or any transform. Re-focusing the
same window is idempotent and must not duplicate MRU history.

When creating a window, install its requested content before focusing it so the
new content scene receives the initial focus callback. Keep
`get_focused_window()` temporarily as a compatibility accessor if it avoids
unrelated churn; its result is `focused_window`.

The complete state/placement cutover occurs atomically with the Phase 0 slot
switch described below. Until that commit, retain enough of the old depth code
to keep overlapping planar windows usable. Do not declare an independently
shippable “end of F” state with both flat overlap and no Z ordering.

## 5. Phase 0 geometry

### P0.1. Coordinate convention

The configured user reference is a fixed point in workspace-local space, not a
live head pose. This preserves stable windows while the user leans; later
recenter/follow behavior can move the workspace anchor.

Resolve the origin decision now: `SWindow`'s origin and the circle tangent point
are the **content centre**. The header continues to overhang above it.

For radius `R`, reference point `C`, and slot angle `phi`:

```text
phi(LEFT)   = -theta
phi(CENTRE) = 0
phi(RIGHT)  = +theta

centre(phi) = C + R * (sin(phi), 0, -cos(phi))
basis(phi)  = Basis(UP, -phi)
```

`slot_transform(slot)` returns `Transform3D(basis, centre)` and is assigned to
the window's **local** `transform` under the identity `WindowLayer`.

Pin Godot's signs with tests rather than comments alone:

- `RIGHT` has positive local X.
- `LEFT` has negative local X.
- `basis.z.dot(C - centre) > 0` for every slot.
- `basis` is orthonormal and the local X axis is tangent to the circle.

### P0.2. Tunables and validation

Expose one `Layout` export group on `WindowManager`:

- `reference_point: Vector3`, defaulting so the centre window is near the
  current `(0, 1.5, -2)` pose.
- `radius: float` (`R`).
- `slot_angle: float` (`theta`, displayed as degrees in the inspector).
- `gutter_angle: float` (`g`, displayed as degrees).
- `default_half_width: float` (`beta_default`, displayed as degrees).
- `default_height`, `min_height`, and `max_height`.

Derive, never separately configure:

```text
w_default = 2R * tan(beta_default)
beta(w)   = atan(w / (2R))
w(beta)   = 2R * tan(beta)
```

Validate whenever the tunables change, including before creating startup windows.
Split the checks by severity so a bad tune degrades rather than crashes.

Hard preconditions — the geometry is undefined without them. Fail loudly in
debug/headless runs, and in a release build clamp to a sane value rather than
dividing by zero or taking `tan` of a right angle:

- `R > 0`.
- `0 < theta < PI/2`.
- `0 < beta_default < PI/2`.
- `g >= 0`.
- `min_height <= default_height <= max_height`, all within numeric safety limits.

Fit constraints — the math still runs, but windows may overlap or be clamped
below their default. Emit one non-fatal warning per violation; never abort:

- `g < theta`.
- `2 * beta_default + g <= theta`, so adjacent default windows fit.
- `w_default` is within the numeric width safety limits.
- Numeric minimum width is no greater than `w_default`.

The geometry is scale-similar only when `R` and every metre size scale together.
Changing `R` at runtime does not silently rescale existing `content_size` values;
it re-runs the checks above, so a violation warns rather than passing unnoticed.

### P0.3. Permutation-safe width clamp

Let `beta_1 >= beta_2` be the two widest angular half-widths among all open
windows. The manager maintains:

```text
beta_1 + beta_2 + g <= theta
```

This is sufficient because `theta` is the smallest separation between any two
slots. It deliberately applies to stashed windows too: every open window must be
safe beside every other open window before Phase 2 can cycle or Phase 3 can move
it without refusal or implicit resizing.

For a request concerning window `i`:

```text
largest_other = max(beta_default, max beta(j) for open j != i)
beta_i_max    = theta - g - largest_other
w_i_max       = 2R * tan(beta_i_max)
```

`max_content_width_for(win)` scans `open_windows` directly rather than caching
the two leaders; a removal can expose an unknown third value and the collection
is deliberately small. Return `min(numeric_max_width, w_i_max)`. Do not floor an
invalid maximum up to the numeric minimum, because that could violate the
angular invariant; startup validation must guarantee that a numeric-minimum
window is legal beside a default window.

`clamp_content_size()` clamps width to
`[numeric_min_width, max_content_width_for(win)]` and height to the configured
height range intersected with numeric safety limits.

After every managed size commit, the following must hold over all open windows:

```text
beta_1 + beta_2 + g <= theta
```

At gesture start, compute and store this cap on `SWindow` after the manager has
granted exclusive resize ownership. Non-gesture calls compute a fresh cap for
that single atomic request. Recompute by scanning whenever the open set or a
content width changes; do not maintain a cached global top-two index.

### P0.4. Open and close lifecycle

Replace positional creation with:

```gdscript
create_window(content: PackedScene = null) -> SWindow
```

Opening:

1. Find the first empty slot in `CENTRE`, `RIGHT`, `LEFT` order.
2. If none exists, return `null` and issue one clear warning without
   instantiating or mutating state. Phase 2 replaces this rejection with stash
   behavior.
3. Instantiate, assign the manager reference, and reconnect the window's
   `on_closed`/`on_focused` signals to the manager (the header press routes
   through the general focus handler; the old positional wiring is gone).
4. Parent under `WindowLayer`, add to `open_windows`, occupy the slot, and apply
   its slot transform.
5. Install content, apply `(w_default, default_height)` through the managed size
   path, then focus it.

A caller may immediately request another initial size through `resize()`; it is
clamped for that slot and never changes an existing window. The application menu
opens at the default size, the same as the terminal — no special browse-friendly
request — so nothing relies on a width the clamp might refuse.

Closing:

1. Identify and clear the closed window's slot.
2. Remove it from `open_windows` and `focus_history`.
3. If it was focused, clear focus and focus the first still-valid, slotted MRU
   entry.
4. If no history entry survives but a window remains, use the first occupied (CENTRE, then RIGHT, then LEFT)
   slot as a defensive fallback.
5. Do not compact slots or move survivors.

Update startup creation to use this path. The menu occupies `CENTRE`; the
terminal occupies `RIGHT` and is focused at startup, matching current behaviour.
Sparse states such as `[LEFT, empty, RIGHT]` remain valid.

In the same atomic cutover:

- Delete `bring_to_front`, `send_to_back`, `move_forward`, `move_backward`, and
  `_recalculate_z_order`.
- Delete `z_order`, `Z_STEP`, `LAYER_ORIGIN_Z`, and `apply_z_order` from
  `SWindow`.
- Delete `world_bounds`, free-drag state/methods, and the header drag event
  branch. Keep header press connected to the general focus handler.
- Reduce `_process()` to resize-resolution throttling.
- Remove obsolete drag cleanup from `close()`.

### P0.5. Resize affordances and hover routing

Keep the existing invisible handle bodies. Add separate unshaded white visual
children:

- two short local-axis segments for `BL` and `BR`, forming corner marks;
- one short centred segment for each of `L`, `R`, and `B`;
- no top affordance.

Lay them out with the handles in window-local coordinates and put them slightly
toward the viewer to avoid Z fighting. They do not get collision of their own.

In `HandPointer._process_hit_test()`, deliver target `EXITED` and `ENTERED`
events in that order whenever `_current_target` changes, while retaining the
pointer's existing public hover signals. Cache the last hover position so an
exit has a meaningful event position. Preserve target locking during a pinch.

The window shows an affordance on `ENTERED` and hides it on `EXITED` or resize
end, as the parent specifies. Hiding on release intentionally suppresses it
until the pointer exits and re-enters that handle. Keep the pointer's current
target intact so the next real exit is still delivered; do not synthesize a
second enter immediately after release.

The display-width inequality does not automatically account for collision bands
that protrude into the gutter. Add a configured-layout pickability test at legal
maximum widths. If adjacent handles are ambiguous, reserve their outer angular
margin in the clamp or increase the gutter; do not restore per-window Z offsets.

## 6. Tests

Run affected suites on macOS with Godot 4.5, `--headless --xr-mode off`. This
work does not touch freedesktop files, icons, generated shell scripts, or process
handling, so the Linux container is not required. Do not claim OpenXR comfort,
hand tracking, or rendering performance without board testing.

### Existing suite changes

- Replace `tests/zorder_test.gd` with a slot/focus/lifecycle suite. Z-depth and
  “focused means frontmost” are deleted contracts.
- Rewrite `tests/resize_clamp_test.gd` for fixed-centre behavior and the
  permutation-safe angular cap. Its helper must close each temporary
  window or construct a clean manager; startup windows plus the three-window
  limit make its current accumulating pattern invalid.
- Update `tests/resize_handle_test.gd`: a `0.3 m` edge displacement changes the
  dimension by `0.6 m`; remove the next-Z-layer test; retain band tiling,
  thickness, collision-mask, and pickability checks; add affordance visibility.
- Update `tests/window_size_check.gd` for fixed centre, doubled edge deltas,
  rotated axes, and the managed resize path.
- Update `tests/app_search_focus_test.gd` to use `open_windows` and find the
  keyboard below `KeyboardAnchor`.
- Update `tests/virtual_keyboard_input_test.gd` for the keyboard's new parent.
- Update any remaining `windows_list`, positional `create_window`, or Z-order
  references found by `rg`.

### State and lifecycle assertions

- Startup occupies `CENTRE`, then `RIGHT`; the third open uses `LEFT`.
- Startup focuses the terminal (`RIGHT`), and both startup windows open at the
  default size.
- A fourth open returns `null` and changes no state.
- Focus changes no slot, transform, open-list order, or `content_size`.
- Repeated focus creates no duplicate history entries.
- Closing a focused window promotes the most recent surviving window.
- Closing a non-focused window leaves focus unchanged.
- Closing creates a sparse slot and moves no survivor.
- Content is installed before its initial focus notification.
- Phase 0's public paths leave the stash empty and solo state null. Full stash
  transitions are not tested until Phase 2; only the Phase 0 clamp's required
  treatment of a valid stashed fixture is covered now.
- A model-level slot/stash/reassignment fixture changes only placement state;
  the window's `content_size` is unchanged. It does not expose stashing as a
  Phase 0 user operation.

### Geometry and resize assertions

- Every slot centre is exactly `R` from `C`.
- The window face normal points to `C`; local X is tangent; RIGHT is positive X.
- Each lateral display endpoint is farther from `C` than the centre is.
- Focus and resize never change a slot/window transform.
- Equal local pointer displacement produces equal size change at yaw `0`,
  `+theta`, and `-theta`.
- Every supported handle changes only its intended dimensions and keeps the
  centre fixed, including after overshooting and recovering from a clamp.
- Public/programmatic `resize()` cannot bypass the angular bound.
- The cap is `theta - g - max(beta_default, largest other open beta)`.
- The two-widest invariant holds after every open, close, and resize.
- A valid stashed fixture constrains the cap even though it occupies no slot.
- Every permutation of the open windows into the three slots satisfies each
  occupied pair's geometric inequality.
- A second simultaneous resize gesture is rejected or deferred, and closing
  the active window clears manager resize ownership.
- Opening a default window into any empty slot moves/resizes no survivor.
- A fit-constraint violation (e.g. `2 * beta_default + g > theta`) warns but still
  builds the layout; a hard-precondition violation is rejected or clamped.

### Hover and keyboard assertions

- `HandPointer` sends one target `ENTERED`/`EXITED` pair on target transitions
  and retains its public hover signals.
- Affordances show on enter, stay shown during resize, hide on resize end, and
  become eligible to show again after exit/re-entry.
- Keyboard visibility and key routing follow `focused_window`, including after
  closing the focused window and after closing the last window.

## 7. Device-only acceptance

On the target headset, tune `R`, `theta`, `g`, `beta_default`, height limits,
and handle/affordance dimensions. Verify readability, reach, pointer selection,
and resize feel with both side slots occupied. These are not headless-test
claims.

## 8. Commit sequence

Keep every commit parseable and its affected tests green:

1. Add `WindowLayer`/`KeyboardAnchor`, reparent the keyboard, and update keyboard
   discovery tests without changing window placement.
2. Introduce the single managed resize gateway (`clamp_content_size`) while it
   still performs only numeric clamping; no member rename.
3. Implement rotation-safe fixed-centre resize and rewrite its focused tests.
4. Add pure slot geometry, tunable validation, and permutation-cap helpers with
   headless unit coverage, but do not switch live placement yet.
5. Atomically switch lifecycle/focus to explicit state and tangent slots; remove
   the old Z stack and free drag; replace the Z-order suite and update startup
   tests. Width safety is not enforced between this step and step 6, so two wide
   neighbours can overlap; do not assert non-overlap here.
6. Enable the permutation-safe clamp for every managed size path and add
   opening/full-capacity/sparse-layout coverage.
7. Add target hover delivery and resize affordances with transition tests.

Phases F + 0 are complete only after steps 1–7 pass together.
