class_name WindowManager extends Node3D

# Creates windows from the window.tscn template and owns the stack order.
# List position IS the z-order: the last element is frontmost and is the focused
# window, so every reorder is a list move followed by _recalculate_z_order().

@export_group("References")
@export var window: PackedScene
@export var keyboard: PackedScene

## The three persistent tangent slots. LEFT/RIGHT sit at -/+ slot_angle from the
## CENTRE slot on the arc. Introduced now for the geometry helpers; live slot
## placement is switched on in a later step.
enum Slot { LEFT, CENTRE, RIGHT }

@export_group("Layout")
## Fixed workspace-local point the slot arc curves around. Defaults so the CENTRE
## slot lands near the legacy (0, 1.5, -2) window pose at the default radius.
@export var reference_point := Vector3(0.0, 1.5, 0.0)
## Arc radius R: distance from reference_point to every slot's content centre.
@export var radius := 2.0
## Angular separation theta between adjacent slots (stored in radians).
@export_range(1.0, 89.0, 0.1, "radians_as_degrees") var slot_angle := deg_to_rad(45.0)
## Empty gutter g kept between adjacent windows (stored in radians).
@export_range(0.0, 89.0, 0.1, "radians_as_degrees") var gutter_angle := deg_to_rad(5.0)
## Default window angular half-width beta_default (stored in radians).
@export_range(1.0, 89.0, 0.1, "radians_as_degrees") var default_half_width := deg_to_rad(18.0)
@export var default_height := 0.9
@export var min_height := 0.2
@export var max_height := 2.5

# Every open window lives in exactly one slot or the stash. The permutation-safe
# width cap scans this set; slot/stash/focus lifecycle wiring is switched on in a
# later step, so live placement still runs through windows_list for now.
var open_windows: Array[SWindow] = []

var windows_list: Array[SWindow] = []
var _focused: SWindow = null


## Spawns a window at `pos` showing `content`, focused and frontmost.
func create_window(pos: Vector3 = Vector3.ZERO, content: PackedScene = null) -> SWindow:
	var win: SWindow = window.instantiate()
	win.manager = self
	win.position = pos
	add_child(win)
	windows_list.append(win)

	win.on_closed.connect(func(): _on_window_closed(win))
	win.on_focused.connect(_on_window_focused)

	# Focusing also assigns the top z-order, so a new window needs nothing else
	_on_window_focused(win)

	if content:
		win.set_content(content)

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
	# The only route virtual keys take. The keyboard emits this signal rather than
	# injecting into the Input singleton, so nothing else in the tree ever sees
	# them -- typing cannot drive the simulator's WASD locomotion.
	if not _focused:
		return
	_focused.send_input(event)


## Closes `win`. Ignored when it is not in the stack.
func destroy_window(win: SWindow) -> void:
	if win in windows_list:
		win.close()


## Brings `win` to the front of the stack. Ignored when it is not in the stack.
func bring_to_front(win: SWindow) -> void:
	if win not in windows_list:
		return

	windows_list.erase(win)
	windows_list.append(win)
	_recalculate_z_order()


## Sends `win` to the back of the stack. Ignored when it is not in the stack.
func send_to_back(win: SWindow) -> void:
	if win not in windows_list:
		return

	windows_list.erase(win)
	windows_list.insert(0, win)
	_recalculate_z_order()


## Moves `win` one level forward. Ignored when it is not in the stack or is
## already frontmost.
func move_forward(win: SWindow) -> void:
	if win not in windows_list:
		return

	var index = windows_list.find(win)
	if index < windows_list.size() - 1:
		var other = windows_list[index + 1]
		windows_list[index] = other
		windows_list[index + 1] = win
		_recalculate_z_order()


## Moves `win` one level backward. Ignored when it is not in the stack or is
## already backmost.
func move_backward(win: Node3D) -> void:
	if win not in windows_list:
		return

	var index = windows_list.find(win)
	if index > 0:
		var other = windows_list[index - 1]
		windows_list[index] = other
		windows_list[index - 1] = win
		_recalculate_z_order()


## Clamps `desired` to the size policy for `win`. The single gateway every
## managed size request passes through, so no caller can bypass the policy.
## Numeric-only for now; the angular permutation bound is wired in here in a
## later step, once max_content_width_for governs live placement.
func clamp_content_size(win: SWindow, desired: Vector2) -> Vector2:
	return desired.clamp(win.MIN_CONTENT_SIZE, win.MAX_CONTENT_SIZE)


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


## Widest content width `win` may take while every open window remains safe in
## every slot permutation: beta_i + beta_other + gutter <= theta against the
## widest OTHER open window, never counting an other narrower than a default one.
## Scans open_windows so a removal that exposes a new leader is caught; a stashed
## window still counts because it too must stay safe beside every neighbour.
## Returns the numeric width limit when the angular bound is looser. The result
## is intentionally not floored up to the numeric minimum: startup validation
## guarantees a numeric-minimum window is legal beside a default one.
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


## Get the currently focused (frontmost) window
func get_focused_window() -> SWindow:
	return _focused


## Reassigns every window's z-order from its list position and updates the
## focused-window highlight to match.
func _recalculate_z_order() -> void:
	var top_index = windows_list.size() - 1
	for i in windows_list.size():
		var win = windows_list[i] as SWindow
		if is_instance_valid(win):
			win.z_order = i
			win.apply_z_order()
			win.set_focused_visual(i == top_index)


## Drops a closed window from the stack and promotes the next frontmost one.
func _on_window_closed(win: Node3D) -> void:
	windows_list.erase(win)
	if win == _focused:
		_focused = null
	_recalculate_z_order()
	# promote the new frontmost window so input focus matches the visual state
	if not _focused and not windows_list.is_empty():
		_on_window_focused(windows_list[-1])


## Focuses `win`, bringing it to the front and routing input to it. No-op when
## it is already the focused window.
func _on_window_focused(win: SWindow) -> void:
	# Idempotent so re-pressing the focused window cannot reshuffle the stack
	# mid-gesture, which is what used to knock depth off the Z_STEP grid
	if win == _focused:
		return

	if _focused:
		_focused.set_input_enabled(false)

	bring_to_front(win)
	win.set_input_enabled(true)
	_focused = win


func _ready() -> void:
	# Check the Layout tunables before any geometry depends on them.
	validate_tunables()

	# TEMP: hardcoded startup windows, pending a real session/launcher flow
	# Browse-friendly size for the application list.
	create_window(Vector3(-0.3, 1.5, -2.0),
			load("res://project/launch_service/application_menu.tscn")).resize(Vector2(2.4, 1.4))
	# TODO: Make terminal_ui's fixed-size children fill the viewport and let its
	# output expand vertically before choosing a new terminal startup size.
	create_window(Vector3(0.3, 1.5, -2.0), load("res://project/shell/terminal_ui.tscn"))
	
	create_keyboard()
