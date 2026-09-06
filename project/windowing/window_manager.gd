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

@export_group("Layout")
## Fixed workspace-local point the slot arc curves around. Defaults so the CENTRE
## slot lands near the legacy (0, 1.5, -2) window pose at the default radius.
@export var reference_point := Vector3(0.0, 1.5, 0.0)
## Arc radius R: distance from reference_point to every slot's content centre.
@export var radius := 3.0
## Angular separation theta between adjacent slots (stored in radians).
@export_range(1.0, 89.0, 0.1, "radians_as_degrees") var slot_angle := deg_to_rad(45.0)
## Empty gutter g kept between adjacent windows (stored in radians).
@export_range(0.0, 89.0, 0.1, "radians_as_degrees") var gutter_angle := deg_to_rad(2.0)
## Default window angular half-width beta_default (stored in radians).
@export_range(1.0, 89.0, 0.1, "radians_as_degrees") var default_half_width := deg_to_rad(18.0)
@export var default_height := 0.9
@export var min_height := 0.2
@export var max_height := 2.5

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

# The window currently granted exclusive resize ownership, or null. Only one
# window may resize at a time: the cap it froze at gesture start stays valid
# because no other window's width can change underneath it.
var resizing_window: SWindow = null


## Opens a window showing `content` in the first empty slot (CENTRE, then RIGHT,
## then LEFT), sizes it to the layout default, and focuses it. Returns null and
## warns without mutating state when all three slots are occupied.
func create_window(content: PackedScene = null) -> SWindow:
	var slot := _first_empty_slot()
	if slot == -1:
		push_warning("All three slots are occupied; ignoring the window request.")
		return null

	var win: SWindow = window.instantiate()
	win.manager = self
	win.on_closed.connect(func(): _on_window_closed(win))
	win.on_focused.connect(focus)

	$WindowLayer.add_child(win)
	open_windows.append(win)
	_assign_slot(win, slot)

	# Install content before the initial focus so the content scene receives its
	# first on_window_focus_changed callback.
	if content:
		win.set_content(content)
	win.resize(Vector2(default_width(), default_height))
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


## Drops a closed window from all state and, if it was focused, promotes the most
## recent surviving slotted window. Survivors are never moved or resized, so a
## sparse slot layout is left as-is.
func _on_window_closed(win: SWindow) -> void:
	release_resize(win) # closing the active window clears resize ownership
	_clear_slot(win)
	open_windows.erase(win)
	focus_history.erase(win)
	if win == focused_window:
		focused_window = null
		_focus_after_close()
	_update_focus_visuals()


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
