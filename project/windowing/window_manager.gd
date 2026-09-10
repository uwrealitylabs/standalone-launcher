class_name WindowManager extends Node3D

# Creates windows from the window.tscn template and owns their placement: each
# open window occupies one of three persistent tangent slots on an arc, and the
# manager is the sole writer of window transforms. Focus is tracked separately and
# changes only input routing, MRU history, and header styling.

@export_group("References")
@export var window: PackedScene
@export var keyboard: PackedScene

## The three persistent tangent slots. LEFT/RIGHT sit at -/+ slot_angle from the
## CENTRE slot on the arc. Array-indexed as slots[Slot], so the numeric order
## LEFT, CENTRE, RIGHT is load-bearing; fill/fallback order is chosen explicitly.
enum Slot { LEFT, CENTRE, RIGHT }

## Solo presentation state. DOCKED is the ordinary multi-window layout; ENTERING
## and EXITING bracket the animated transition (making its direction explicit and
## acting as a hard gate); SOLO is one window presented alone. soloed_window is set
## throughout ENTERING, SOLO and EXITING.
enum Presentation { DOCKED, ENTERING, SOLO, EXITING }

@export_group("Layout")
## Fixed workspace-local point the slot arc curves around. Kept at the player's
## head pose so the arc always curves around the viewer; radius alone then sets
## how far in front each window sits. The CENTRE slot lands at z = -radius.
@export var reference_point := Vector3(0.0, 1.5, 0.0)
## Arc radius R: distance from reference_point to every slot's content centre,
## i.e. how far in front of the player the CENTRE window sits.
@export var radius := 3.0
## Angular separation theta between adjacent slots (stored in radians).
@export_range(1.0, 89.0, 0.1, "radians_as_degrees") var slot_angle := deg_to_rad(45.0)
## Empty gutter g kept between adjacent windows (stored in radians).
@export_range(0.0, 89.0, 0.1, "radians_as_degrees") var gutter_angle := deg_to_rad(3.0)
## Default window angular half-width beta_default (stored in radians).
@export_range(1.0, 89.0, 0.1, "radians_as_degrees") var default_half_width := deg_to_rad(18.0)
@export var default_height := 0.9
@export var min_height := 0.2
@export var max_height := 2.5
## Default content size a window takes on entering solo. Device-tunable; validated
## to lie within [MIN_CONTENT_SIZE, MAX_CONTENT_SIZE].
@export var default_solo_size := Vector2(1.4, 0.9)
## Duration of the solo enter/exit tween, seconds. 0 runs the commit synchronously
## (tests / reduced motion), so the state never rests mid-transition. Device-tunable.
@export var solo_transition_duration := 0.25

# Explicit lifetime/placement/focus state. Invariants: every open window sits in
# exactly one slot or once in stashed_queue; focused_window is open and slotted
# (or null when no slot is occupied); focus_history holds each open window once,
# most-recent first. In Phase 0 the stash and solo state stay empty.
var open_windows: Array[SWindow] = []
var slots: Array[SWindow] = [null, null, null]
var stashed_queue: Array[SWindow] = []
var focused_window: SWindow = null
var focus_history: Array[SWindow] = [] # index 0 is most recent
var soloed_window: SWindow = null

# Solo state machine. _solo_state gates every transition; _solo_tween is the live
# enter/exit tween (null when none). _solo_token is a generation counter bumped on
# every new tween and on close-interruption, so a stale tween_method step or
# finished callback returns immediately instead of writing a freed or re-presented
# window.
var _solo_state := Presentation.DOCKED
var _solo_tween: Tween = null
var _solo_token := 0
signal solo_entered(win)
signal solo_exited()

# The window currently granted exclusive resize ownership, or null. Only one
# window may resize at a time: the cap it froze at gesture start stays valid
# because no other window's width can change underneath it.
var resizing_window: SWindow = null


## Public request to open a window showing `content` while a solo presentation may
## be active. Async: it unsolos first (awaiting the exit tween) so creation always
## commits in the docked layout. The slot preflight runs BEFORE ensure_docked, so a
## full workspace returns null without tearing down a live solo just to fail. A slot
## may close during the await, which is fine — _create_window_now re-checks. Returns
## the new window, or null when the workspace is full or a transition is in flight.
func request_open_window(content: PackedScene = null) -> SWindow:
	if _first_empty_slot() == -1:
		return null
	if not await ensure_docked():
		return null
	return _create_window_now(content)


## Thin docked-path wrapper: opens a window with no solo semantics. Startup and the
## existing test callers use this; it commits synchronously and never awaits.
func create_window(content: PackedScene = null) -> SWindow:
	return _create_window_now(content)


## Synchronous commit that opens a window showing `content` in the first empty slot
## (CENTRE, then RIGHT, then LEFT), sizes it to the layout default, and focuses it.
## Self-enforces the state gate — warns and returns null unless DOCKED — so no
## caller can create a window mid-transition or behind a solo. Returns null and
## warns without mutating state when all three slots are occupied.
func _create_window_now(content: PackedScene = null) -> SWindow:
	if _solo_state != Presentation.DOCKED:
		push_warning("Window creation is only allowed in the docked layout; ignoring.")
		return null
	var slot := _first_empty_slot()
	if slot == -1:
		push_warning("All three slots are occupied; ignoring the window request.")
		return null
	cancel_active_resize()

	var win: SWindow = window.instantiate()
	win.manager = self
	win.on_closed.connect(func(): _on_window_closed(win))
	win.on_focused.connect(focus)

	$WindowLayer.add_child(win)
	open_windows.append(win)
	_assign_slot(win, slot)

	# Install content before the initial focus so the content scene receives its
	# first on_window_focus_changed callback. Size through the internal policy, not
	# resize(): the fresh window is not interactive yet (its slot is assigned but
	# the interaction gate would reject it), so it must bypass resize_window.
	if content:
		win.set_content(content)
	win._apply_resize_request(Vector2(default_width(), default_height))
	focus(win)

	return win


## Creates a virtual keyboard under KeyboardAnchor, linking its input to the
## windowing system. The anchor carries the authored pose; the keyboard is an
## identity child of it. Always visible: hiding it would stop rendering but leave
## its collider pickable, so keys could still be pressed on an invisible board.
func create_keyboard() -> void:
	var kb: Node3D = keyboard.instantiate()
	$KeyboardAnchor.add_child(kb)

	var kb_2d: XRToolsVirtualKeyboard2D = kb.get_scene_instance()
	kb_2d.key_pressed.connect(_on_key_pressed)


## Invoked on (virtual) keyboard input
func _on_key_pressed(event: InputEventKey) -> void:
	# The only route virtual keys take: the keyboard emits this signal instead of
	# injecting into the Input singleton, so typing can't drive simulator locomotion.
	if not focused_window:
		return
	focused_window.send_input(event)


## Closes `win`. Ignored when it is not open.
func destroy_window(win: SWindow) -> void:
	if win in open_windows:
		win.close()


# --- Slot helpers ----------------------------------------------------------
# The single path that mutates slot occupancy and slot transforms. None of them
# reads or writes content_size, so later stash/reorder phases reuse them without
# exposing those features here.

## The slot `win` occupies, or -1 when it is not slotted (e.g. stashed).
func _slot_of(win: SWindow) -> int:
	return slots.find(win)


## Puts `win` in `slot` and applies that slot's transform. Placement only.
func _assign_slot(win: SWindow, slot: Slot) -> void:
	slots[slot] = win
	win.transform = slot_transform(slot)


## Empties whichever slot `win` occupies. No-op when it is not slotted.
func _clear_slot(win: SWindow) -> void:
	var i := slots.find(win)
	if i != -1:
		slots[i] = null


## First empty slot in fill order (CENTRE, RIGHT, LEFT), or -1 when all full.
func _first_empty_slot() -> int:
	for slot in [Slot.CENTRE, Slot.RIGHT, Slot.LEFT]:
		if slots[slot] == null:
			return slot
	return -1


## Clamps `desired` to the size policy for `win`: the single gateway every managed
## size request passes through. Width is bounded by the permutation-safe angular
## cap (no size change pushes two windows closer than one slot); height by the
## configured range intersected with the numeric limits. During a resize the width
## cap is the one frozen at gesture start; every other call recomputes it.
func clamp_content_size(win: SWindow, desired: Vector2) -> Vector2:
	var max_w: float = win._resize_max_width if win._resizing else max_content_width_for(win)
	var min_h: float = maxf(min_height, win.MIN_CONTENT_SIZE.y)
	var max_h: float = minf(max_height, win.MAX_CONTENT_SIZE.y)
	return Vector2(
			clampf(desired.x, win.MIN_CONTENT_SIZE.x, max_w),
			clampf(desired.y, min_h, max_h))


## Clamps `desired` to solo safety limits only — the numeric
## [MIN_CONTENT_SIZE, MAX_CONTENT_SIZE] range in Phase 1. Unlike
## [method clamp_content_size] it never consults the angular budget or a frozen
## width cap: a soloed window is centred and alone, so no pairwise slot constraint
## applies. Real FOV/render-target/comfort limits are device-tuned later.
func clamp_solo_size(win: SWindow, desired: Vector2) -> Vector2:
	return desired.clamp(win.MIN_CONTENT_SIZE, win.MAX_CONTENT_SIZE)


## Grants `win` exclusive resize ownership. Returns false without changing state
## when another still-valid window already holds it, so a second simultaneous
## gesture is refused rather than corrupting the frozen cap. Idempotent for the
## current owner.
func acquire_resize(win: SWindow) -> bool:
	if resizing_window != null and resizing_window != win \
			and is_instance_valid(resizing_window):
		return false
	resizing_window = win
	return true


## Releases `win`'s resize ownership. No-op when it is not the owner.
func release_resize(win: SWindow) -> void:
	if resizing_window == win:
		resizing_window = null


## Cancels the active resize gesture, if any: the owning window ends its drag,
## resets its frozen cap, and settles at its current size. The single point that
## clears an in-flight gesture before a transition or a conflicting programmatic
## resize. No-op when no window is resizing.
func cancel_active_resize() -> void:
	if resizing_window != null and is_instance_valid(resizing_window):
		resizing_window.cancel_resize()  # clears resizing_window via release_resize
	else:
		resizing_window = null


## State-gated programmatic resize of `win` to `desired`. The public entry every
## non-gesture resize takes (SWindow.resize delegates here). Rejects the request
## unless can_interact(win) allows it in the current state — so mid-transition
## (ENTERING/EXITING) all resizes are refused, and in SOLO only the soloed window
## resizes (a suspended sibling is rejected, its content_size untouched). Cancels
## any active gesture unconditionally — including on the actively dragged window
## itself, so a following pointer frame cannot resurrect the stale gesture and
## overwrite this result — then applies through the window's internal policy.
func resize_window(win: SWindow, desired: Vector2) -> void:
	if not is_instance_valid(win) or win not in open_windows:
		return
	if not can_interact(win):
		return
	cancel_active_resize()
	win._apply_resize_request(desired)


## Whether `win` may be interacted with (resized) in the current presentation
## state. In SOLO only the soloed window qualifies; in DOCKED any valid open,
## slotted window does (start_resize focuses first and a docked focus request
## always succeeds, so the pressed window becomes interactive); mid-transition
## (ENTERING/EXITING) no window does. A defensive backstop — the interaction lock
## and sibling suspension do the real work.
func can_interact(win: SWindow) -> bool:
	match _solo_state:
		Presentation.SOLO:
			return win == soloed_window
		Presentation.DOCKED:
			return is_instance_valid(win) and win in open_windows and _slot_of(win) != -1
		_:
			return false


# --- Phase 0 slot geometry -------------------------------------------------
# Pure functions of the Layout tunables. They describe where a slot sits and how
# wide a window may grow; they do not read or mutate live window state beyond
# scanning open_windows for the width cap.

## Signed slot angle phi: LEFT = -theta, CENTRE = 0, RIGHT = +theta.
func slot_phi(slot: Slot) -> float:
	match slot:
		Slot.LEFT:
			return -slot_angle
		Slot.RIGHT:
			return slot_angle
		_:
			return 0.0


## Local transform of `slot` under the identity WindowLayer: the content centre
## sits on the arc at radius R, and the face is turned to look back toward
## reference_point. Local +X is tangent to the circle.
func slot_transform(slot: Slot) -> Transform3D:
	var phi := slot_phi(slot)
	var centre := reference_point + radius * Vector3(sin(phi), 0.0, -cos(phi))
	return Transform3D(Basis(Vector3.UP, -phi), centre)


## Default content width derived from the default angular half-width.
func default_width() -> float:
	return 2.0 * radius * tan(default_half_width)


## Angular half-width a content width `w` subtends at the arc radius.
func beta_of_width(w: float) -> float:
	return atan(w / (2.0 * radius))


## Content width for an angular half-width `beta`.
func width_of_beta(beta: float) -> float:
	return 2.0 * radius * tan(beta)


## Widest content width `win` may take while every open window stays safe in every
## slot permutation: beta_i + beta_other + gutter <= theta against the widest OTHER
## open window, never counting one narrower than a default. Scans open_windows so a
## removal exposing a new leader is caught (stashed windows count too). Returns the
## numeric width limit when the angular bound is looser; deliberately not floored to
## the numeric minimum, which startup validation already guarantees is legal.
func max_content_width_for(win: SWindow) -> float:
	var largest_other := default_half_width
	for other in open_windows:
		if other == win or not is_instance_valid(other):
			continue
		largest_other = maxf(largest_other, beta_of_width(other.content_size.x))
	var beta_max := slot_angle - gutter_angle - largest_other
	return minf(SWindow.MAX_CONTENT_SIZE.x, width_of_beta(beta_max))


## Checks the Layout tunables, split by severity so a bad tune degrades rather
## than crashes. Hard preconditions leave the geometry undefined: each is
## reported loudly and clamped to a safe value so later math cannot divide by
## zero or take tan of a right angle. Fit constraints still evaluate but may let
## windows overlap or clamp below default: each warns once and never aborts.
func validate_tunables() -> void:
	# Hard preconditions.
	if radius <= 0.0:
		push_error("Layout.radius must be > 0; clamping to a safe value.")
		radius = 0.001
	if slot_angle <= 0.0 or slot_angle >= PI / 2.0:
		push_error("Layout.slot_angle must be in (0, PI/2); clamping.")
		slot_angle = clampf(slot_angle, 0.001, PI / 2.0 - 0.001)
	if default_half_width <= 0.0 or default_half_width >= PI / 2.0:
		push_error("Layout.default_half_width must be in (0, PI/2); clamping.")
		default_half_width = clampf(default_half_width, 0.001, PI / 2.0 - 0.001)
	if gutter_angle < 0.0:
		push_error("Layout.gutter_angle must be >= 0; clamping to 0.")
		gutter_angle = 0.0
	var safe_min: float = SWindow.MIN_CONTENT_SIZE.y
	var safe_max: float = SWindow.MAX_CONTENT_SIZE.y
	min_height = clampf(min_height, safe_min, safe_max)
	max_height = clampf(max_height, safe_min, safe_max)
	if min_height > max_height or default_height < min_height or default_height > max_height:
		push_error("Layout heights must satisfy min <= default <= max within the "
				+ "numeric limits; clamping.")
		max_height = maxf(max_height, min_height)
		default_height = clampf(default_height, min_height, max_height)
	var solo_clamped: Vector2 = default_solo_size.clamp(
			SWindow.MIN_CONTENT_SIZE, SWindow.MAX_CONTENT_SIZE)
	if not solo_clamped.is_equal_approx(default_solo_size):
		push_error("Layout.default_solo_size must lie within the numeric content "
				+ "limits; clamping.")
		default_solo_size = solo_clamped
	if solo_transition_duration < 0.0:
		push_error("Layout.solo_transition_duration must be >= 0; clamping to 0.")
		solo_transition_duration = 0.0

	# Fit constraints.
	if gutter_angle >= slot_angle:
		push_warning("Layout.gutter_angle >= slot_angle: adjacent slots leave no room.")
	if 2.0 * default_half_width + gutter_angle > slot_angle:
		push_warning("Two default windows plus the gutter exceed slot_angle; "
				+ "adjacent default windows may overlap.")
	var w_default := default_width()
	if w_default < SWindow.MIN_CONTENT_SIZE.x or w_default > SWindow.MAX_CONTENT_SIZE.x:
		push_warning("Default width %.3f falls outside the numeric width limits." % w_default)
	if SWindow.MIN_CONTENT_SIZE.x > w_default:
		push_warning("Numeric minimum width exceeds the default width.")


## The currently focused window, or null when no slot is occupied. Compatibility
## accessor; focused_window is the field of record.
func get_focused_window() -> SWindow:
	return focused_window


## Focuses `win`: routes keyboard/gamepad input to it, moves it to the front of
## the MRU history, and updates header styling. It changes no slot, transform, or
## open-list order, and never touches content_size. Idempotent, and a no-op for a
## window that is not open, not slotted, or suspended behind a solo presentation.
func focus(win: SWindow) -> void:
	if not is_instance_valid(win) or win not in open_windows:
		return
	if _slot_of(win) == -1:
		return # a stashed window cannot be focused
	if soloed_window != null and win != soloed_window:
		return # suspended behind a solo presentation
	if win == focused_window:
		return # idempotent; must not duplicate MRU history

	if focused_window and is_instance_valid(focused_window):
		focused_window.set_input_enabled(false)

	focus_history.erase(win)
	focus_history.push_front(win)
	focused_window = win
	win.set_input_enabled(true)
	_update_focus_visuals()


## Dims every window's header except the focused one's.
func _update_focus_visuals() -> void:
	for win in open_windows:
		if is_instance_valid(win):
			win.set_focused_visual(win == focused_window)


# --- Solo mode -------------------------------------------------------------
# A presentation mode layered over focus: one window moves to CENTRE, resizes to
# default_solo_size, and every other window is suspended. Its slot and content_size
# are untouched. Transitions are animated by a manager-owned tween; ENTERING and
# EXITING reject all optional layout-mutating operations.

## Enters solo mode on `win`: focuses it, suspends every other open window, and
## animates it to the CENTRE slot at default_solo_size. Rejected unless currently
## DOCKED and `win` is open and slotted. Emits solo_entered on completion.
func enter_solo(win: SWindow) -> void:
	if _solo_state != Presentation.DOCKED:
		return
	if not is_instance_valid(win) or win not in open_windows or _slot_of(win) == -1:
		return
	cancel_active_resize()
	focus(win)
	_solo_state = Presentation.ENTERING
	soloed_window = win
	# Start size = the visible content size, so the animation begins where the
	# window actually is.
	win.current_solo_size = win.content_size
	win.set_interaction_locked(true)
	for other in open_windows:
		if other != win and is_instance_valid(other):
			other.set_suspended(true)

	win.set_transitioning(true)
	_start_transition(win, win.transform, slot_transform(Slot.CENTRE),
			win.content_size, clamp_solo_size(win, default_solo_size),
			Presentation.ENTERING)


## Exits solo mode, animating the soloed window back to its slot and content_size
## and restoring the docked layout. Rejected unless currently SOLO. Emits
## solo_exited on completion.
func exit_solo() -> void:
	if _solo_state != Presentation.SOLO:
		return
	cancel_active_resize()
	var win := soloed_window
	_solo_state = Presentation.EXITING
	win.set_transitioning(true)
	win.set_interaction_locked(true)
	# Siblings stay suspended (non-interactive) for the whole exit tween.
	_start_transition(win, win.transform, slot_transform(_slot_of(win)),
			win.current_solo_size, win.content_size, Presentation.EXITING)


## Ensures the workspace is in the docked layout, awaiting a solo exit if needed.
## The single primitive external operations use when they require docked layout.
## Returns true once DOCKED; false when a transition is already in flight (rejected,
## not queued — the caller retries later). Async: from SOLO it triggers exit_solo
## and awaits solo_exited.
func ensure_docked() -> bool:
	match _solo_state:
		Presentation.DOCKED:
			return true
		Presentation.SOLO:
			exit_solo()
			# Load-bearing: a zero-duration exit commits synchronously inside
			# exit_solo and has already emitted solo_exited by now, so awaiting it
			# unconditionally would hang forever. Only await when still EXITING.
			if _solo_state == Presentation.EXITING:
				await solo_exited
			return _solo_state == Presentation.DOCKED
		_:
			return false


## Bumps the generation counter, invalidating any in-flight tween's step and
## finished callbacks, and returns the new token.
func _new_solo_token() -> int:
	_solo_token += 1
	return _solo_token


## Drives a solo transition from (start_xf, from_size) to (target_xf, to_size)
## over solo_transition_duration for `phase` (ENTERING/EXITING). A zero duration
## commits synchronously so the state never rests mid-transition; otherwise a
## cubic-in-out tween interpolates and its finished handler commits exactly.
func _start_transition(win: SWindow, start_xf: Transform3D, target_xf: Transform3D,
		from_size: Vector2, to_size: Vector2, phase: Presentation) -> void:
	var tok := _new_solo_token()
	if solo_transition_duration <= 0.0:
		_commit_transition(tok, win, target_xf, to_size, phase)
		return
	_solo_tween = create_tween()
	_solo_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_solo_tween.tween_method(
			_solo_step.bind(tok, win, start_xf, target_xf, from_size, to_size, phase),
			0.0, 1.0, solo_transition_duration)
	_solo_tween.finished.connect(
			_commit_transition.bind(tok, win, target_xf, to_size, phase))


## One tween frame: interpolates transform and presentation size at progress `t`.
## Guards first on the token, phase and window validity, so a stale or superseded
## tween writes nothing.
func _solo_step(t: float, tok: int, win: SWindow, start_xf: Transform3D,
		target_xf: Transform3D, from_size: Vector2, to_size: Vector2,
		phase: Presentation) -> void:
	if tok != _solo_token or _solo_state != phase or not is_instance_valid(win):
		return
	win.transform = start_xf.interpolate_with(target_xf, t)
	win.current_solo_size = from_size.lerp(to_size, t)
	win._apply_size(win.current_solo_size, true)


## Snaps a transition to its exact target and settles the docked/solo state.
## Guards on token, phase and validity so a killed or superseded transition
## commits nothing. Applies the exact size first (settling resolution
## synchronously), then clears the transitioning flag.
func _commit_transition(tok: int, win: SWindow, target_xf: Transform3D,
		final_size: Vector2, phase: Presentation) -> void:
	if tok != _solo_token or _solo_state != phase or not is_instance_valid(win):
		return
	win.transform = target_xf
	win.current_solo_size = final_size
	win._apply_size(final_size, false)
	win.set_transitioning(false)
	_solo_tween = null
	if phase == Presentation.ENTERING:
		win.set_interaction_locked(false)
		_solo_state = Presentation.SOLO
		emit_signal("solo_entered", win)
	else:
		_commit_exit(win)


## Exit commit: normalizes the workspace back to the docked layout and emits
## solo_exited. Reactivates every sibling, discards the solo size, clears solo
## state, and re-routes the soloed window's input (focus stays on it).
func _commit_exit(win: SWindow) -> void:
	for other in open_windows:
		if other != win and is_instance_valid(other):
			other.set_suspended(false)
	win.current_solo_size = Vector2.ZERO
	soloed_window = null
	_solo_state = Presentation.DOCKED
	win.set_interaction_locked(false)  # re-routes input since focused_window == win
	emit_signal("solo_exited")


## Drops a closed window from all state and, if it was focused, promotes the most
## recent surviving slotted window. Survivors are never moved or resized, so a
## sparse slot layout is left as-is. If the closing window was soloed, first resets
## every transition field defensively (a UI close is impossible mid-tween — the
## buttons are dead — so this covers programmatic teardown / disappearance).
func _on_window_closed(win: SWindow) -> void:
	var was_soloed := win == soloed_window
	if was_soloed:
		cancel_active_resize()
		if _solo_tween != null:
			_solo_tween.kill()
		_solo_tween = null
		_solo_token += 1  # invalidate any pending step/finished callback
		if is_instance_valid(win):
			win.set_transitioning(false)
		# Load-bearing: while soloed_window != null, focus() rejects every survivor,
		# so clear it before _focus_after_close can promote one.
		soloed_window = null
		_solo_state = Presentation.DOCKED
		for other in open_windows:
			if other != win and is_instance_valid(other):
				other.set_suspended(false)

	release_resize(win) # closing the active window clears resize ownership
	_clear_slot(win)
	open_windows.erase(win)
	focus_history.erase(win)
	# Only a promotion changes focus styling, and _focus_after_close -> focus()
	# refreshes it. Closing a non-focused or the last window leaves every
	# survivor's focus state as it was, so no separate visual refresh is needed.
	if win == focused_window:
		focused_window = null
		_focus_after_close()

	# The killed tween emits no normal completion and the bumped token invalidates
	# any stale finished callback, so this is the sole solo_exited for the close.
	if was_soloed:
		emit_signal("solo_exited")


## After the focused window closes, focus the most recent surviving slotted
## window; failing that, the first occupied slot (CENTRE, RIGHT, LEFT). Leaves
## focus null when no window remains.
func _focus_after_close() -> void:
	for win in focus_history:
		if is_instance_valid(win) and _slot_of(win) != -1:
			focus(win)
			return
	for slot in [Slot.CENTRE, Slot.RIGHT, Slot.LEFT]:
		var win: SWindow = slots[slot]
		if win != null and is_instance_valid(win):
			focus(win)
			return


func _ready() -> void:
	# Check the Layout tunables before any geometry depends on them.
	validate_tunables()

	# TEMP: hardcoded startup windows, pending a real session/launcher flow.
	# The menu takes CENTRE; the terminal takes RIGHT and, opening last, is
	# focused. Both open at the layout default size.
	create_window(load("res://project/launch_service/application_menu.tscn"))
	create_window(load("res://project/shell/terminal_ui.tscn"))

	create_keyboard()
