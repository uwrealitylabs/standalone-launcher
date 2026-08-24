class_name WindowManager extends Node3D

# Creates windows from the window.tscn template and owns the stack order.
# List position IS the z-order: the last element is frontmost and is the focused
# window, so every reorder is a list move followed by _recalculate_z_order().

@export_group("References")
@export var window: PackedScene
@export var keyboard: PackedScene

var windows_list: Array[SWindow] = []
var _focused: SWindow = null


## Spawns a window at `pos` showing `content`, focused and frontmost.
func create_window(pos: Vector3 = Vector3.ZERO, content: PackedScene = null) -> SWindow:
	var win: SWindow = window.instantiate()
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


## Creates a virtual keyboard, linking its input to the windowing system
func create_keyboard() -> void:
	var kb: Node3D = keyboard.instantiate()
	add_child(kb)
	kb.position = Vector3(0, 0, -1)  # TEMP HARDCODED
	kb.rotation_degrees = Vector3(-35, 0, 0)  # TEMP HARDCODED
	
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
	# TEMP: hardcoded startup windows, pending a real session/launcher flow
	var win1: SWindow = create_window(Vector3(-0.3, 1.5, -2.0))
	create_window(Vector3(0.3, 1.5, -2.0), load("res://project/shell/terminal_ui.tscn"))
	
	create_keyboard()
