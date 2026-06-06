class_name WindowManager extends Node

# Window creator and manager system
# Instantiates new window using window.tscn template and stores it in an array
# Manages z-ordering so focused windows appear in front

@export_group("References")
@export var window: PackedScene
@export var keyboard: PackedScene

var windows_list: Array[SWindow] = []
var _focused: SWindow = null


func create_window(pos: Vector3 = Vector3.ZERO, content: PackedScene = null) -> SWindow:
	var win: SWindow = window.instantiate()
	win.position = pos
	add_child(win)
	windows_list.append(win)

	# connect signals
	win.on_closed.connect(func(): _on_window_closed(win))
	win.on_focused.connect(_on_window_focused)

	# new window gets top z-order
	#bring_to_front(win)
	
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
	if not XRUtils.is_openxr_active():  # In editor, only map virtual keyboard input to windows
		if not _focused:
			return
		print(_focused)
		_focused.send_input(event)


func destroy_window(win: SWindow) -> void:
	if win in windows_list:
		win.close()


## Bring a specific window to the front of the stack
func bring_to_front(win: SWindow) -> void:
	if win not in windows_list:
		return

	# move this window to the end of the list
	windows_list.erase(win)
	windows_list.append(win)

	# reassign z-order values based on list position
	_recalculate_z_order()


## Send a specific window to the back of the stack
func send_to_back(win: SWindow) -> void:
	if win not in windows_list:
		return

	# move this window to the beginning of the list
	windows_list.erase(win)
	windows_list.insert(0, win)

	# reassign z-order values based on list position
	_recalculate_z_order()


## Move a window one level forward in the stack
func move_forward(win: SWindow) -> void:
	if win not in windows_list:
		return

	var index = windows_list.find(win)
	if index < windows_list.size() - 1:
		# swap with the window above it
		var other = windows_list[index + 1]
		windows_list[index] = other
		windows_list[index + 1] = win
		_recalculate_z_order()


## Move a window one level backward in the stack
func move_backward(win: Node3D) -> void:
	if win not in windows_list:
		return

	var index = windows_list.find(win)
	if index > 0:
		# swap with the window below it
		var other = windows_list[index - 1]
		windows_list[index] = other
		windows_list[index - 1] = win
		_recalculate_z_order()


## Get the currently focused (frontmost) window
func get_focused_window() -> SWindow:
	return _focused


## Recalculate z-order for all windows based on their position in the list
func _recalculate_z_order() -> void:
	var top_index = windows_list.size() - 1
	for i in windows_list.size():
		var win = windows_list[i] as SWindow
		if is_instance_valid(win):
			win.z_order = i
			win.apply_z_order()
			win.set_focused_visual(i == top_index)


# Remove window from window manager list and recalculate z-order
func _on_window_closed(win: Node3D) -> void:
	print("removed from window list")
	windows_list.erase(win)
	_recalculate_z_order()


# Handle window focus request
func _on_window_focused(win: SWindow) -> void:
	if _focused:
		_focused.set_input_enabled(false)
	
	bring_to_front(win)
	win.set_input_enabled(true)
	_focused = win
	


func _ready() -> void:
	# TESTING
	var win1: SWindow = create_window(Vector3(-0.3, 1.5, -2.0))
	create_window(Vector3(0.3, 1.5, -2.0), load("res://project/shell/terminal_ui.tscn"))
	
	create_keyboard()
