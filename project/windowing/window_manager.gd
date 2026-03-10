extends Node3D
# Window creator and manager system
# Instantiates new window using window.tscn template and stores it in an array

@export var window_scene: PackedScene
@export var left_controller: XRController3D
@export var right_controller: XRController3D
var windows_list: Array[Node3D] = []
var _active_window: StandaloneWindow = null

#using controllers to drag, we can change this later
var _dragging_controller: XRController3D = null
var _left_was_pressed := false
var _right_was_pressed := false

func create_window(pos: Vector3 = Vector3.ZERO) -> Node3D:
	var win: StandaloneWindow = window_scene.instantiate()
	win.position = pos
	add_child(win)
	windows_list.append(win)
	win.on_closed.connect(func(): _on_window_closed(win))
	return win

func destroy_window(win: Node3D) -> void:
	if win in windows_list:
		win.close()

# Remove window from window manager list
func _on_window_closed(win: Node3D) -> void:
	print("removed from window list")
	windows_list.erase(win)

#Casts ray from controller, checks if it hit window and drags if it does
func _try_start_drag(controller: XRController3D) -> void:
	var hit = _get_ray_hit(controller)
	if hit.is_empty():
		return
	var win = _find_window_parent(hit.collider)
	if not win:
		return
	_active_window = win
	_dragging_controller = controller
	_active_window.start_drag(hit.position)

func _update_active_drag(delta: float) -> void:
	if not _active_window or not _dragging_controller:
		return
	var hit = _get_ray_hit(_dragging_controller)
	if not hit.is_empty():
		_active_window.update_drag(hit.position, delta)

func _stop_active_drag() -> void:
	if not _active_window:
		return
	_active_window.stop_drag()
	_active_window = null
	_dragging_controller = null

#Casts ray, returns a filled dictionary if hits window
func _get_ray_hit(controller: XRController3D) -> Dictionary:
	if not controller:
		return {}
	var ray_start = controller.global_position
	var ray_direction = -controller.global_transform.basis.z 
	var ray_end = ray_start + (ray_direction * 20.0) #TODO update numbers based on scene
	var params = PhysicsRayQueryParameters3D.create(ray_start, ray_end)
	params.exclude = [controller.get_rid()] 
	return get_world_3d().direct_space_state.intersect_ray(params)

#Runs every physics frame and handles the drag functionality
func _physics_process(delta: float) -> void:
	if _active_window and _dragging_controller:
		if _dragging_controller.is_button_pressed("trigger_click"):
			_update_active_drag(delta)
		else:
			_stop_active_drag()
		return
	var left_pressed  = left_controller  and left_controller.is_button_pressed("trigger_click")
	var right_pressed = right_controller and right_controller.is_button_pressed("trigger_click")

	# try to start drag on the first frame of the press
	if left_pressed and not _left_was_pressed:
		_try_start_drag(left_controller)
	elif right_pressed and not _right_was_pressed:
		_try_start_drag(right_controller)
	_left_was_pressed  = left_pressed
	_right_was_pressed = right_pressed

#Only hit the window, not other objects
func _find_window_parent(node: Node) -> StandaloneWindow:
	var current = node
	while current:
		if current is StandaloneWindow:
			return current
		current = current.get_parent()
	return null

func _ready() -> void:
	# Create test windows, delete in future
	var win1 = create_window(Vector3(-1.2, 0.5, 0))
	var rect1 = ColorRect.new()
	rect1.color = Color.SKY_BLUE
	rect1.set_anchors_preset(Control.PRESET_FULL_RECT)
	win1.set_content(rect1)
	
	var win2 = create_window(Vector3(1.2, 0.5, 0))
	var rect2 = ColorRect.new()
	rect2.color = Color.PALE_VIOLET_RED
	rect2.set_anchors_preset(Control.PRESET_FULL_RECT)
	win2.set_content(rect2)
	
	# Manually testing the close function
	await get_tree().create_timer(3.0).timeout
	win2.close()
