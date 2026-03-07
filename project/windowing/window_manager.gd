extends Node3D

# Window creator and manager system
# Instantiates new window using window.tscn template and stores it in an array
# Manages z-ordering so focused windows appear in front

@export var window_scene: PackedScene

var windows_list: Array[Node3D] = []


func create_window(pos: Vector3 = Vector3.ZERO) -> Node3D:
	var win: StandaloneWindow = window_scene.instantiate()
	win.position = pos
	add_child(win)
	windows_list.append(win)

	# connect signals
	win.on_closed.connect(func(): _on_window_closed(win))
	win.on_focused.connect(_on_window_focused)

	# new window gets top z-order
	bring_to_front(win)

	return win


func destroy_window(win: Node3D) -> void:
	if win in windows_list:
		win.close()


## Bring a specific window to the front of the stack
func bring_to_front(win: Node3D) -> void:
	if win not in windows_list:
		return

	# move this window to the end of the list
	windows_list.erase(win)
	windows_list.append(win)

	# reassign z-order values based on list position
	_recalculate_z_order()


## Send a specific window to the back of the stack
func send_to_back(win: Node3D) -> void:
	if win not in windows_list:
		return

	# move this window to the beginning of the list
	windows_list.erase(win)
	windows_list.insert(0, win)

	# reassign z-order values based on list position
	_recalculate_z_order()


## Move a window one level forward in the stack
func move_forward(win: Node3D) -> void:
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
func get_focused_window() -> Node3D:
	if windows_list.size() > 0:
		return windows_list[windows_list.size() - 1]
	return null


## Recalculate z-order for all windows based on their position in the list
func _recalculate_z_order() -> void:
	var top_index = windows_list.size() - 1
	for i in windows_list.size():
		var win = windows_list[i] as StandaloneWindow
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
func _on_window_focused(win: StandaloneWindow) -> void:
	bring_to_front(win)


func _ready() -> void:
	var win1 = create_window(Vector3(-0.3, 1.5, -2.0))
	var rect1 = ColorRect.new()
	rect1.color = Color.SKY_BLUE
	rect1.set_anchors_preset(Control.PRESET_FULL_RECT)
	win1.set_content(rect1)

	var win2 = create_window(Vector3(0.3, 1.5, -2.0))
	var rect2 = ColorRect.new()
	rect2.color = Color.PALE_VIOLET_RED
	rect2.set_anchors_preset(Control.PRESET_FULL_RECT)
	win2.set_content(rect2)
