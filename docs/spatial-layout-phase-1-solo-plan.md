# Implementation plan — Spatial window layout, Phase 1: Solo mode

## Context

The launcher (Godot 4.5, GDScript, OpenXR) presents up to three windows on a fixed
three-slot tangent arc (Phases F + 0, already landed on this branch). **Solo mode**
temporarily presents one window by itself: it becomes focused, moves to the workspace
centre, resizes to a default solo size, and every other window is suspended. Its docked
slot and docked size are untouched — solo is a *presentation* mode layered over focus,
not a new kind of focus.

The groundwork exists: `WindowManager` owns all transforms, tracks `soloed_window`
(declared but unused), `focus()` already rejects windows "suspended behind a solo
presentation" (`window_manager.gd:283`), resize has a single-owner lock, and
`clamp_content_size`/`max_content_width_for` enforce the docked angular budget.

**Naming constraint (explicit):** the persistent docked size **keeps the variable name
`content_size`** — no rename, ever (`docked_size` is a conceptual name only). Every new
comment about the docked size must say so against `content_size` — e.g. on the
declaration: *"`content_size` is the persistent docked size (spec: `docked_size`); solo
uses `current_solo_size` instead."*

**Transitions are animated in Phase 1** via a **manager-owned tween** (device-tunable
duration). Enter/exit interpolate transform and presentation size in parallel and emit a
completion signal only after snapping to the exact target and settling resolution.

## Key files

- `project/windowing/swindow.gd` — size/geometry/resize/suspend/interaction split.
- `project/windowing/window_manager.gd` — solo state machine, tween, `ensure_docked()`.
- `project/windowing/window_header.gd` + `window_header.tscn` — the solo button.
- `tests/solo_mode_test.gd` (new) + `tests/support/window_fixtures.gd` (extend if needed).

---

## 1. Size-state split (`swindow.gd`)

- Keep `content_size` as the **persistent docked size** (add the naming note above).
- Add `var current_solo_size := Vector2.ZERO` — the animated/live solo size; meaningful
  only while this window is `manager.soloed_window` (i.e. manager state is
  ENTERING/SOLO/EXITING). Reset to `Vector2.ZERO` after exit completes.
- Add `WindowManager` `@export var default_solo_size := Vector2(1.4, 0.9)` (Layout group;
  matches the spec example; device-tunable). Validate in `validate_tunables()` to lie
  within `[MIN_CONTENT_SIZE, MAX_CONTENT_SIZE]`.

**`_apply_size` becomes the mode-independent geometry writer** (it is not "pure" — it
mutates geometry, resolution state, and render targets; it just no longer decides *which*
size field is authoritative). Strip the persistent `content_size = …` assignment out of it;
it drives quad/collision/viewport/handles/affordances from its `size` argument and stores
`_active_size := size` for the resolution subsystem — it writes **no** persistent size
field. Callers own the field write:

- `_apply_resize_request(desired, live)` is the internal policy method that branches (see
  §4 for who calls it — gesture frames and the external `resize_window` path, never a
  bare public `resize()`):
  - **solo path** (`manager and manager.soloed_window == self`): `current_solo_size =
    manager.clamp_solo_size(self, desired)`, then `_apply_size(current_solo_size, live)`.
  - **docked path**: `content_size = manager.clamp_content_size(self, desired)` (numeric
    fallback when unmanaged), then `_apply_size(content_size, live)`.
- **Transitions bypass `resize()` policy selection** (finding: calling
  `win.resize(content_size)` while `soloed_window == win` wrongly takes the solo branch).
  The manager drives tween frames by setting `current_solo_size = sample` directly and
  calling `win._apply_size(sample, true)`. Exact commit calls `win._apply_size(target,
  false)`; on exit the target is `content_size`, which is read, never written.
- **All "current size" reads become solo-aware.** Add `func _presentation_size()`
  returning `current_solo_size if (manager and manager.soloed_window == self) else
  content_size`. Fix the three sites that hardcode `content_size`:
  - `start_resize` caches `_resize_start_size = _presentation_size()`.
  - `stop_resize` settles `_apply_size(_presentation_size(), false)`.
  - The resolution throttle — `_commit_resolution`, `_stretch_exceeded`/`_res_basis`,
    `_tick_resolution` — reads `_active_size`, not `content_size`.
- `WindowManager.clamp_solo_size(win, desired)` clamps to solo safety limits only —
  `[MIN_CONTENT_SIZE, MAX_CONTENT_SIZE]` in Phase 1 — and **never** consults the angular
  budget or `_resize_max_width`. Real FOV/render-target/comfort limits are device-tuned
  later (spec §2); do not fabricate them.
- **`max_content_width_for` is unchanged** — it keeps reading other windows' `content_size`
  (docked), so it never sees solo size (spec §2). This is the payoff of keeping the name.

## 2. Separate interaction, routing, and focus notification (`swindow.gd`)

`set_input_enabled(false)` currently also fires `on_window_focus_changed(false)`
(`swindow.gd:148,157`). Locking the soloed window during a tween must **not** report a
focus loss, since `focused_window` never changed. Split the concerns:

- `_set_key_routing(enabled)` — the `content_3d.input_keyboard/input_gamepad` +
  `header_3d.input_keyboard` flags **only** (no content hook).
- `_notify_content_focus(enabled)` — the `on_window_focus_changed` hook only.
- `set_input_enabled(enabled)` (kept, used by manager `focus()`) = `_set_key_routing` +
  `_notify_content_focus`. Preserves today's focus behaviour.

Presentation/interaction API. Add a per-window `var is_suspended := false`; both setters are
**idempotent** (early-return if the requested state already holds) so repeated
suspend/reactivate during overlapping transitions is safe.

- `set_suspended(true)` (a sibling while any window is soloed): set `is_suspended = true`;
  hide both surfaces (`content_3d.visible = header_3d.visible = false`). The addon disables a
  surface's screen collider **through visibility** — `_update_enabled` computes `disabled =
  !enabled or not is_visible_in_tree()` ([viewport_2d_in_3d.gd:471](/Users/lirunheng/Desktop/WRL-S26/standalone-launcher/addons/godot-xr-tools/objects/viewport_2d_in_3d.gd:471))
  — so it leaves `content_3d.enabled` **unchanged**; hiding also stops redraw (`UPDATE_ONCE`).
  Then **explicitly** disable each resize handle's `CollisionShape3D` (handles are separate
  `StaticBody3D`s under `ResizeHandles`, not covered by the surface cascade),
  `_clear_hover_affordances()` (below), `_set_key_routing(false)`, and call optional
  `on_window_suspended(true)`. `set_suspended(false)` reverses visibility / redraw / handle
  collision, and **calls `on_window_suspended(false)`** on restore; it does **not** route
  input (focus owns that).
- `set_interaction_locked(locked)` (the soloed window for the whole tween): toggles **only**
  collision + key routing; mesh + redraw stay visible — `content_3d/header_3d.enabled =
  not locked` (this drives the collider via `_update_enabled` since the surfaces stay
  visible), each handle `CollisionShape3D.disabled = locked`, and on lock
  `_clear_hover_affordances()`, `_set_key_routing(not locked && manager.focused_window ==
  self)`. **Unlock derives eligibility from `manager.focused_window == self`** — never a
  blind enable — and never fires the focus hook.
- `_clear_hover_affordances()` — a disabled handle collider that is currently hovered may
  never emit `EXITED`, so its separate visible affordance mesh (`_resize_affordances`, group
  per handle) would hang in the air. Empty every `_affordance_hovers[id]` set and set every
  `_resize_affordances[id].visible = false`. Call it from both setters whenever collision is
  being taken away.

State matrix `{mesh-visible, screen-collision, handle-collision, key-routing, redraw}`:
- soloed mid-tween (locked): `{on, off, off, off, on}`
- soloed committed (unlocked, focused): `{on, on, on, on, on}`
- suspended sibling: `{off, off, off, off, idle after one UPDATE_ONCE}`

**Tests assert the observable truth, not `enabled`:** a suspended sibling has
`content_3d.visible == false`, its `Content`/`Header` screen `CollisionShape3D.disabled ==
true`, and every handle `CollisionShape3D.disabled == true` — **not** `content_3d.enabled ==
false` (which the addon never touches on hide).

## 3. Authoritative interaction gate for resize (`swindow.gd` + `window_manager.gd`)

`start_resize` requests focus but proceeds regardless of acceptance (`swindow.gd:188,191`),
so a revealed/half-suspended window could resize itself. Add
`WindowManager.can_interact(win)`:
- state `SOLO`: true only for `win == soloed_window`.
- state `DOCKED`: true for **any** valid, open, slotted window — because `start_resize`
  focuses first and a docked focus request always succeeds, so the pressed window becomes
  interactive. It is **not** restricted to whichever window was focused before the press.
- state `ENTERING`/`EXITING`: false for every window (no window is interactive mid-tween).

`start_resize` aborts before `acquire_resize` if `not manager.can_interact(self)` (checked
after its `focus()` call, so the docked case sees the just-granted focus). Siblings also stay
fully suspended for the entire exit tween (reactivated only at exit commit), so their handles
are dead throughout — belt and braces.

**Single owner of `set_process`.** `_process` currently gates on `_resizing` alone
(`swindow.gd:174`), and both `stop_resize` and `close`/cancel call `set_process(false)` bare
(`swindow.gd:248,534`) — so a resize ending mid-transition (or vice-versa) would silently
switch resolution ticking off while the tween still needs it. Add `var _transitioning :=
false` with a setter `set_transitioning(on)` and route **all** process toggling through one
helper `_update_processing()` that calls `set_process(_resizing or _transitioning)`. Replace
every bare `set_process(true/false)` with a field write + `_update_processing()`. The manager
calls `set_transitioning(true)` when it starts a tween on the window and `false` at exact
commit / on kill.

## 4. Gesture vs. external resize (`swindow.gd` + `window_manager.gd`)

Gesture frames call the resize policy themselves, so the *gesture* must not route through the
programmatic entry (which cancels gestures) — and a same-window programmatic resize that does
**not** cancel leaves stale gesture state (the next pointer frame recomputes from the old
`_resize_start_local`/`_resize_start_size` and overwrites the programmatic result). Separate
the two entries:

- **Gesture** (`update_resize`): calls the internal `_apply_resize_request(..., true)`
  directly (§1) — no cancel, keeps its own gesture state.
- **Programmatic**: `WindowManager.resize_window(win, desired)` is the state-gated entry. It
  **validates the target first** (window open + `can_interact`, per the contract below), then
  **`cancel_active_resize()` unconditionally** — including when `win` is itself the actively
  dragged window — and only then applies via `win._apply_resize_request(desired)` (never via
  `win.resize()`, which would recurse). This is what the "conflicting programmatic resize
  cancels the active gesture" test targets and what prevents the same-window overwrite.
- **`SWindow.resize(desired)` stays as the public programmatic wrapper** (repo reality: three
  tests and creation call it): when managed it delegates to `manager.resize_window(self,
  desired)`; unmanaged it falls back to the numeric clamp + `_apply_size`. Existing callers
  keep working and now get the cancel + state gate for free. It is **not** on the gesture path
  anymore, so its cancel is safe.
- **`resize_window` state contract** (make this explicit — `can_interact` already enforces it,
  but state it so intent is unambiguous):
  - `DOCKED`: resize any valid open/slotted window.
  - `SOLO`: resize **only** `soloed_window`; a suspended sibling is **rejected** (`can_interact`
    is true only for the soloed window in SOLO).
  - `ENTERING`/`EXITING`: **reject all** resize requests.
  No deferred-sibling-resize path is added — no current caller resizes a suspended sibling.
- **Creation sizing bypasses the gate.** `_create_window_now` currently sizes the fresh window
  with `win.resize(Vector2(default_width(), default_height))` (`window_manager.gd:74`); the new
  window may not be slotted yet, so `can_interact` would reject it. Change that one call to the
  internal `win._apply_resize_request(Vector2(default_width(), default_height))` (docked path,
  settled) so creation is not subject to the interaction gate.
- `cancel_active_resize()` (centralized, spec §7): if `resizing_window` valid, call
  `SWindow.cancel_resize()` — ends the gesture, `release_resize`, resets `_resize_max_width`
  to default, settles `_apply_size(_presentation_size(), false)`, and clears gesture state so
  no later pointer frame resumes it; does **not** revert size.

## 5. Solo state machine + tween (`window_manager.gd`)

Replace the boolean with an explicit enum (spec §11, finding: state races):

```gdscript
enum Presentation { DOCKED, ENTERING, SOLO, EXITING }
var _solo_state := Presentation.DOCKED
var _solo_tween: Tween = null
var _solo_token := 0                       # generation; invalidates stale callbacks
signal solo_entered(win)
signal solo_exited()
@export var solo_transition_duration := 0.25   # seconds, 0.2–0.3
```

`ENTERING` and `EXITING` exist mainly to make the transition **direction** explicit and to be
a hard gate.

**Transition invariant.** During `ENTERING` and `EXITING`, reject all *optional* external
operations that mutate window geometry, slot/layout state, or presentation state. The only
work allowed is the solo tween and its rendering/resolution bookkeeping. The known entry
points already satisfy this:

| Entry point            | How it's blocked mid-transition                     |
|------------------------|-----------------------------------------------------|
| resize gesture         | interaction lock + `can_interact` false             |
| programmatic resize    | `resize_window` rejects (state gate)                |
| Solo button            | soloed window locked; siblings suspended → inert    |
| Close (UI)             | header collision off → button inaccessible          |
| open window            | `ensure_docked()` returns false                     |
| `_create_window_now`   | self-rejects unless `_solo_state == DOCKED`         |

When implementing, **audit any other `WindowManager` layout-mutating entry point against this
invariant** and gate it the same way, rather than inventing per-operation queue behavior.
`can_interact()` (§3) is a defensive backstop, not the primary guard — the lock + suspension
do the real work.

**Lifecycle events are the exception.** A window actually disappearing (freed, closed
programmatically) cannot be "rejected"; §7 handles it defensively by restoring consistent
state instead.

**Tween conventions** (apply to both enter and exit):
- `validate_tunables()` asserts `solo_transition_duration >= 0`.
- Ease: cubic in-out (`Tween.TRANS_CUBIC`, `EASE_IN_OUT`) on the `0→1` progress
  `tween_method`.
- **Zero duration** (tests / reduced-motion): if `solo_transition_duration <= 0`, skip the
  tween entirely and run the exact-commit path synchronously (still through the same
  suspend → commit → signal sequence), so `_solo_state` never rests in ENTERING/EXITING.
- Capture the **live** start pose: `start_xf = win.transform` at the moment the tween begins
  (not a recomputed `slot_transform(...)`), so a re-entered or mid-motion transition
  interpolates from where the window actually is.
- The size targets are clamped through `clamp_solo_size()` (enter target) even though
  `default_solo_size` is tunable-validated — the runtime clamp is authoritative.
- `set_transitioning(true)` on the soloed window when the tween starts; `false` at exact
  commit and on kill (§3, single `set_process` owner).

`soloed_window` is **set throughout ENTERING, SOLO and EXITING** (never cleared early), so
the `focus()` guard (`window_manager.gd:283`) stays authoritative for the whole transition.

**enter_solo(win)** — reject unless `_solo_state == DOCKED` and `win` is open+slotted:
1. `cancel_active_resize()`; `focus(win)`; `_solo_state = ENTERING`; `soloed_window = win`.
2. `win.current_solo_size = win.content_size` (start size = the visible docked size).
3. `win.set_interaction_locked(true)`; suspend every other open window (`set_suspended(true)`).
4. `win.set_transitioning(true)`; start a tween (`_new_solo_tween()` bumps `_solo_token` and
   captures `tok := _solo_token`): a `tween_method` on progress `0→1` over the duration drives
   `_solo_step(tok, win, start_xf, target_xf, from_size, to_size, t)`. **`_solo_step` guards
   first** — return immediately unless `tok == _solo_token and _solo_state == ENTERING and
   is_instance_valid(win)` — then `win.transform = start_xf.interpolate_with(target_xf, t)`
   (proper rotation interp); `win.current_solo_size = from_size.lerp(to_size, t)`;
   `win._apply_size(win.current_solo_size, true)`. Enter: `start_xf = win.transform` (live),
   `target_xf = slot_transform(CENTRE)`, `from_size = content_size`,
   `to_size = clamp_solo_size(win, default_solo_size)`.
5. On `finished` (guard `tok == _solo_token and _solo_state == ENTERING`): snap exact —
   `win.transform = target_xf`; `var final := clamp_solo_size(win, default_solo_size)`;
   `win.current_solo_size = final`; `win._apply_size(final, false)` (settles resolution);
   `win.set_transitioning(false)`; `win.set_interaction_locked(false)`; `_solo_tween = null`;
   `_solo_state = SOLO`; `emit_signal("solo_entered", win)`. (No auto-exit hook — a workspace
   request may arrive during ENTERING but is rejected by `ensure_docked()`/the state gate; §6.)

**exit_solo()** — reject unless `_solo_state == SOLO`:
1. `cancel_active_resize()`; `var win := soloed_window`; `_solo_state = EXITING`.
2. `win.set_transitioning(true)`; `win.set_interaction_locked(true)`; siblings stay suspended
   (non-interactive) for the tween.
3. Tween as above with `start_xf = win.transform` (live centre), `target_xf =
   slot_transform(_slot_of(win))`, `from_size = win.current_solo_size`, `to_size =
   win.content_size`. `content_size` is the read target, never written. `_solo_step` guards
   on `_solo_state == EXITING`.
4. On `finished` (guard `tok == _solo_token and _solo_state == EXITING`): snap exact —
   `win.transform = target_xf`, `win._apply_size(win.content_size, false)`;
   `win.set_transitioning(false)`; `_solo_tween = null`. Then run **exit commit** (§6):
   normalize the workspace and emit `solo_exited`. `solo_exited` means the docked layout is
   restored; there is no deferred work to run after it.

Resolution during the tween: samples use `live = true`, so the SWindow throttle must run.
That is exactly what the §3 `_transitioning` flag + `_update_processing()` provide — the
manager's `set_transitioning(true)` at tween start makes `_process`/`_tick_resolution` run
alongside `_resizing`. At commit the handler **applies the exact size first**
(`_apply_size(target, false)`, which settles resolution synchronously and does not depend on
the `_process` clock), **then** clears `set_transitioning(false)` (matching the step order in
§5's `finished` handlers). Throttled-intermediate + exact-final (spec device note on
render-target reallocation).

## 6. `ensure_docked()` + request/commit window creation (`window_manager.gd`)

Gate on the **state enum, not `soloed_window == null`** (finding: early-clear race). There
is **no** deferred-callable machinery — no `_pending_action`, no queue, no post-signal work.
The rule is: transitions accept **no** new external layout mutation; the one operation that
needs docked layout explicitly **awaits** the current SOLO state exiting, rather than handing
a callable to the manager for later.

**Exit commit.** `exit_solo`'s `finished` handler (§5) just normalizes and emits:
1. Reactivate every other window (`set_suspended(false)`); `win.current_solo_size =
   Vector2.ZERO`; `soloed_window = null`; `_solo_state = DOCKED`; keep focus on `win` and
   `win.set_interaction_locked(false)` (re-routes its input since `focused_window == win`).
2. `emit_signal("solo_exited")`.

**`ensure_docked() -> bool` (async).** The single primitive callers use when an operation
requires docked layout:

```text
DOCKED:            return true
SOLO:              exit_solo()
                   if _solo_state == EXITING: await solo_exited
                   return _solo_state == DOCKED
ENTERING/EXITING:  return false          # reject; do not queue
```

The `if _solo_state == EXITING` check before `await` is **load-bearing**: a zero-duration
transition (§5) commits synchronously inside `exit_solo()` and emits `solo_exited` *before* an
unconditional `await` could register, which would hang forever. When it completed
synchronously the state is already `DOCKED`, so we skip the await.

**Window creation — public request vs internal commit:**

```gdscript
func request_open_window(content):
    if not _first_empty_slot():          # preflight: an impossible open must NOT
        return null                      # tear down a live solo presentation to fail
    if not await ensure_docked():        # unsolo first if needed; false if mid-transition
        return null
    return _create_window_now(content)
```

- `request_open_window` is the public API and is **async** (it may await an exit tween). Its
  slot preflight runs *before* `ensure_docked` so a full workspace never exits Solo just to
  fail; note a slot can close during the await, which is fine — `_create_window_now` re-checks.
- `_create_window_now(content)` is the synchronous commit and **enforces `_solo_state ==
  DOCKED` itself** (warn + return `null` otherwise) so any direct or future caller cannot
  bypass the state gate. It then re-checks `_first_empty_slot()` (belt-and-braces; state/slots
  may have changed across the await); if none, warn and return `null` with no side effects
  (full-refusal contract, `window_manager.gd:56`). Only once a slot is confirmed,
  `cancel_active_resize()`, then instantiate/wire/place/size/focus as today.
- Startup `_ready` calls `_create_window_now` directly in `DOCKED` (never soloed at startup).
  Existing docked test/callers that used `create_window` keep working via a thin public
  wrapper `create_window(content)` → `_create_window_now(content)` (no solo semantics).
- **Caller status (no live wiring in Phase 1).** No current runtime path opens an `SWindow`:
  the launcher creates windows only at startup (`window_manager.gd:343-344`) and via tests,
  and app launches go through `OS.execute()` (external processes), not new `SWindow`s. So
  `request_open_window` has **no live caller today** — it is exercised only by
  `solo_mode_test.gd`. It exists as the correct public entry (plus the `ensure_docked()`
  primitive) for a **future** control that can open a window *while a solo presentation is
  active* — the only case that needs "unsolo first, then create." This plan wires it to no
  existing UI; startup and the three existing test callers keep using the synchronous
  `create_window`/`_create_window_now` path, which never touches solo.

## 7. Closing the soloed window (`window_manager.gd`, spec §10)

**This is defensive handling, not a normal user path.** During `ENTERING`/`EXITING` the
soloed window is interaction-locked and the UI Close/Solo buttons are dead, so a user cannot
close a window mid-tween. What this covers is **programmatic teardown / window disappearance**
— the scene freeing the window, a test closing it, a future non-UI caller. In state `SOLO`
(tween already committed) it is simply the ordinary "close the soloed window" case.

In `_on_window_closed(win)`, before existing removal, if `win == soloed_window`:
1. **Reset every transition field:** `cancel_active_resize()`; if `_solo_tween` is live,
   `_solo_tween.kill()`; `_solo_tween = null`; bump `_solo_token` (invalidates both the
   `tween_method` step and the `finished` callback — a killed tween emits no normal
   completion, and `_solo_step`/`finished` both guard on the token, state, and
   `is_instance_valid(win)`); if `is_instance_valid(win)`, `win.set_transitioning(false)`.
2. `soloed_window = null` **before** `_focus_after_close` — **load-bearing**: while
   `soloed_window != null`, `focus()` rejects every survivor and focus would wrongly stay
   null with slots occupied (`window_manager.gd:283,324`). Set `_solo_state = DOCKED`.
3. Reactivate every other open window (`set_suspended(false)`), synchronously.
4. Fall through to existing removal + `_focus_after_close` (promotes MRU survivor, routes
   keyboard — **not** the closing window); then `emit_signal("solo_exited")` **exactly once**
   (the killed tween + bumped token guarantee no second emit from a stale `finished`). There
   is no deferred work to run — the async `ensure_docked()` callers own their own
   continuation.

## 8. Solo button (`window_header.gd` + `.tscn`, `swindow.gd`)

- Add a `SoloButton` (`Button`) inside `HBoxContainer` **left of** `CloseButton`; simple
  glyph (e.g. `"[ ]"`), tunable later.
- `window_header.gd`: `@onready var solo_button`, `signal solo_pressed()`, wire like
  `close_button`.
- `SWindow`: `signal on_solo_requested(win)`; forward the header's `solo_pressed` to it.
- `_create_window_now` connects `on_solo_requested` (alongside `on_closed`/`on_focused`,
  `window_manager.gd:63-64`) to `_on_solo_requested(win)`, which **guards on `_solo_state`**:
  ignore presses unless `DOCKED` (→ `enter_solo(win)`) or `SOLO` with `win == soloed_window`
  (→ `exit_solo()`); ignore mid-transition presses.

---

## Commit sequence

The numbered sections above are a **reading order**, not a commit order. The state machine,
tween cleanup, and close handling must land **atomically**: once a solo transition is
reachable, close-interruption must already be safe, or a reachable transition can leave
invalid state. Tests ride with the behavior they validate — no test-only final commit.

1. **Size-state refactor, behavior-preserving** (§1). Introduce `_active_size`; make
   `_apply_size` the mode-independent geometry writer; move the persistent size-field write
   **out of `_apply_size` and into `_apply_resize_request`** (the size-policy function); point
   the resolution subsystem at `_active_size`. Keep the existing public `SWindow.resize()`
   **temporarily forwarding directly to `_apply_resize_request`** — not yet through
   `resize_window` — so every current caller and its behavior are unchanged (commit 4 flips
   that wrapper to delegate through `WindowManager.resize_window()` and gain the state/gesture
   gate). The `current_solo_size` field and `_presentation_size()` land here but are
   **dormant** — with `soloed_window` always `null`, `_presentation_size()` returns
   `content_size` and the solo branch of `_apply_resize_request` never runs, so behavior is
   identical. **All existing suites stay green** (`resize_clamp`, `resize_handle`,
   `hover_affordance`, `slot_*`, size checks) — this commit's proof is that they pass unchanged.

2. **Dormant interaction/resize primitives** (§2, §4-SWindow-side). Split `_set_key_routing`
   from `_notify_content_focus`; add idempotent `set_suspended` / `set_interaction_locked`
   with `_clear_hover_affordances`; add `SWindow.cancel_resize()` + manager
   `cancel_active_resize()`; route all process toggling through `set_transitioning` +
   `_update_processing`. Not yet reachable from UI or manager state. Existing suites stay green.

3. **Solo mode — one atomic commit** (§3 `can_interact`, §5 state machine + tween, §6 exit
   commit only, §7 close). This is the **core state machine**: `Presentation`, `_solo_state`,
   `_solo_tween`, `_solo_token`, `current_solo_size` activation, `clamp_solo_size`,
   `default_solo_size`, `enter_solo`, `exit_solo`, the tween lifecycle + exact-commit handlers,
   the exit-commit normalize/emit, `can_interact`, and the `_on_window_closed` interruption
   reset **all land together** — the `_solo_token` guard, state gate, and `_solo_tween.kill()`
   are the re-entrancy protection, so they cannot be split from the machine they protect.
   **`ensure_docked()` is *not* here** — it exists only to let external ops request "get to
   DOCKED first," so it ships with `request_open_window` in commit 4. Reachable only via tests
   at this point (which call `enter_solo`/`exit_solo` directly), not UI. Ships the core
   solo/tween/interruption/close tests **in this commit**.

4. **External-operation surface** (§4-manager-side, §6 `ensure_docked` + request/create split).
   Add `resize_window` (state-gated) and **flip the `SWindow.resize()` wrapper to delegate
   through it** (commit 1 left it forwarding to `_apply_resize_request`); add `ensure_docked()`;
   split async `request_open_window` from synchronous `_create_window_now` (self-enforcing
   `DOCKED`) with the capacity preflight; route creation sizing through `_apply_resize_request`.
   **No deferred-action / queue / finalization machinery** — that was removed in the simplified
   design; transitions **reject** rather than queue, and the only re-entrancy protection already
   shipped in commit 3. Tests: ENTERING/EXITING **rejection** (not queue), async
   open-while-solo, capacity preflight stays in SOLO, zero-duration no-hang.

5. **Header solo button** (§8). Scene node, `solo_pressed` signal, `_on_solo_requested`
   toggle handler guarded on `_solo_state`, glyph/state presentation. Adds the scene-wiring
   tests; re-run `window_scene_check`.

6. **Verification + device tuning.** Run all affected suites headless on macOS (below);
   transition duration/easing, redraw/render-target behavior, and comfort at the solo size are
   **device-only** claims to check on the headset.

## Tests — `tests/solo_mode_test.gd` (new, `extends SceneTree`)

Model on `slot_lifecycle_test.gd`. Await completion via `await wm.solo_entered` / `await
wm.solo_exited`. Two timing/shape hazards to design around:
- **Duration vs CI frame.** A `0.05 s` tween can complete inside a single slow CI frame, so a
  "midpoint" sample may already be at the target. For intermediate-geometry tests, use a
  **generous** `solo_transition_duration` (e.g. `1.0 s`) and sample after one or two
  `process_frame`s, or advance the tween deterministically (`wm._solo_tween.custom_step(dt)`)
  — never rely on a tiny duration to "still be running". Completion tests can use a short
  duration or the zero-duration synchronous path.
- **Differing axes.** Choose `default_solo_size` whose **width and height both differ** from
  the docked `content_size` (the docked and default solo heights can both be `0.9`); an
  intermediate-size assertion that only checks height would pass trivially otherwise.
- **Signal-count wiring.** Forced `solo_exited` on close is **synchronous**, so connect any
  emit counter **before** calling `close()`. To prove no stale/duplicate signal after a
  mid-tween close, `await` past the *original* full `solo_transition_duration` and assert the
  counter is still exactly one.

Cover:

- **Size/layout:** enter preserves slot occupancy and `content_size`; enter ends with
  `current_solo_size == default_solo_size`; solo resize (via `resize_window`) changes only
  `current_solo_size`, not `content_size`/slots/the docked pairwise angular invariant; exit
  restores geometry from `content_size` and transform from the current slot; exit discards
  `current_solo_size` (→ `Vector2.ZERO`); re-entering re-inits from `default_solo_size`.
- **Focus/suspension:** enter focuses the soloed window; siblings become suspended — assert
  `is_suspended == true`, `content_3d.visible == false`, both screen `CollisionShape3D`s
  disabled, **every handle `CollisionShape3D.disabled == true`**, cannot receive
  pointer/keyboard input, `Content/Viewport.render_target_update_mode == UPDATE_ONCE`. Do
  **not** assert `content_3d.enabled == false` (the addon disables the collider through
  visibility and never touches `enabled` on hide). Exit clears `is_suspended` and calls
  `on_window_suspended(false)`; `set_suspended` is idempotent (double-suspend/double-restore
  is a no-op). Normal unsolo keeps focus on the same window.
- **Tween/transition safety:** `content_size` is unchanged on **every** tween frame; geometry
  is genuinely intermediate before completion (sample mid-tween: size strictly between start
  and target); input **and** handle collision stay disabled throughout the tween; final
  `Content/Viewport.size` matches the exact committed size; enter and exit each cancel an
  active gesture; a conflicting `resize_window` on **another** window cancels the active
  gesture before mutating geometry; a `resize_window` on the **actively dragged** window
  itself cancels its gesture (a following `update_resize` frame does not resurrect the old
  `_resize_start_size` and overwrite the programmatic result); `resize_window` is rejected
  (no-op) during `ENTERING`/`EXITING`; a `SOLO`-time `resize_window`/`resize()` targeting a
  **suspended sibling** is rejected (its `content_size` unchanged) while the soloed window
  resizes normally; no stale `_resize_max_width` remains authoritative after cancel. (The
  existing `resize_clamp_test`/`resize_handle_test`/`hover_affordance_test` callers of
  `win.resize()` continue to pass unchanged — they run in `DOCKED` with no active gesture, so
  the wrapper's delegation to `resize_window` preserves the angular-cap behaviour.)
- **State-machine (`ensure_docked` / async open):** `await request_open_window` while
  `DOCKED` opens immediately; while `SOLO` it triggers the animated exit, `solo_exited` fires,
  and the window is created only **after** the state is `DOCKED` (no window exists mid-exit);
  a `request_open_window` issued **during ENTERING or EXITING** returns `null`, creates no
  window, and leaves the in-flight transition to complete normally (state undisturbed). A
  `request_open_window` while `SOLO` **with all slots already full** returns `null` and
  **stays in SOLO** — the slot preflight runs before `ensure_docked`, so an impossible open
  never tears the presentation down. Also assert the **zero-duration** path: with
  `solo_transition_duration == 0`, `ensure_docked()` from `SOLO` returns `true` **without
  hanging** (the synchronous `solo_exited` must not deadlock an unconditional await — this is
  the `if _solo_state == EXITING` guard); and `_create_window_now` called directly while not
  `DOCKED` returns `null` (state gate self-enforced).
- **Hover-affordance safety:** hover a resize handle (drive an `ENTERED`), then suspend /
  interaction-lock the window; assert the handle's affordance group is `visible == false` and
  its `_affordance_hovers` entry is empty — a disabled hovered handle never emits `EXITED`, so
  the stranded-mesh path must be cleared explicitly.
- **Programmatic close mid-transition (defensive, §7):** *programmatically* closing the soloed
  window during enter and during exit (not a UI path — the lock disables the buttons) resets
  all transition fields (`_solo_state == DOCKED`, `soloed_window == null`, `_solo_tween ==
  null`), kills the tween with no stale/duplicate completion signal (assert per the
  signal-count wiring note above), returns survivors to active, promotes MRU focus onto a
  survivor (never the freed window), and leaves the docked layout valid.
- **Contract preservation:** a rejected fourth-window request (all slots full) does **not**
  cancel an active resize.

Add a `window_fixtures.gd` helper if convenient (e.g. `handle_collision(win, id)` for a
handle's `CollisionShape3D`). Existing suites should stay green unchanged.

## Verification

Run headless on macOS (`--xr-mode off` required):

```bash
/Applications/Godot_4.5.0.app/Contents/MacOS/Godot --headless --xr-mode off \
    --path . --script res://tests/solo_mode_test.gd
```

Re-run the windowing suites that share this code — at least `slot_lifecycle_test.gd`,
`slot_geometry_test.gd`, `resize_clamp_test.gd`, `resize_handle_test.gd`,
`hover_affordance_test.gd`, `window_scene_check.gd`, `window_size_check.gd`,
`virtual_keyboard_input_test.gd`, and `app_search_focus_test.gd` (this change touches
suspension/affordance, scene wiring, slot geometry, resize, and focus-on-open) — and confirm
each prints `PASS - all checks passed`. No
`.desktop`/icon/shell/process code is touched, so the Linux container is not required.
Interactive feel is Mac-checkable via the `WRL_SHARE_DIR` run (handoff notes); comfort,
readability, and transition feel at the solo size remain **device-only** claims (below).

## Risks

- **Tween interruption.** The only interruption that can reach a live tween is a window
  actually disappearing (programmatic close/teardown) — normal Solo/Close/resize are
  interaction-locked, and new workspace requests are rejected by the state gate, so there is
  no queued action to fire late. The `_solo_token` generation guard, `_solo_tween.kill()` on
  close, and the state-enum gate on every entry point keep completion exactly-once and
  callbacks off freed windows — the programmatic-close-mid-enter/exit and "no duplicate
  signal" tests pin these; they are the sharpest correctness edges.
- **Intermediate render-target stretch/reallocation.** Tween samples run `live` (throttled),
  so mid-transition frames render the old target stretched; the exact `_apply_size(target,
  false)` at commit reallocates to the final resolution. On-device this must not show a stale
  or blank frame during the reallocation — a device-only check (spec device section).
- **Sibling show/hide timing (chosen, deterministic).** Siblings are suspended at the *start*
  of enter and reactivated only at the *end* of exit — so they are never visible while the
  soloed window overlaps their slots, and never interactive mid-exit. Alternative fade timing
  is a later, centralized tuning decision, not per-caller.
- **Solo clamp is a placeholder.** `clamp_solo_size` uses only numeric min/max in Phase 1;
  real vertical-FOV / comfort / render-target limits are device-tuned before any comfort claim.
