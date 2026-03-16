class_name SWindow extends Node3D

@export_group("Content")
@export var content: PackedScene

@export_group("References")
@export var header_3d: XRToolsViewport2DIn3D
@export var content_3d: XRToolsViewport2DIn3D

signal on_closed()
signal on_focused(win: SWindow)

## This window's depth order (higher = more in front)
var z_order: int = 0

## The depth offset per z-order level (in meters)
const Z_STEP: float = 0.05

## Base position before z-order offset is applied
var base_position: Vector3 = Vector3.ZERO

# Drag state variables
var _dragging    := false
var _drag_offset := Vector3.ZERO
var _drag_target := Vector3.ZERO
var world_bounds := AABB(Vector3(-3, 0.5, -3), Vector3(6, 3, 0)) #update as needed
var _last_valid_hit := Vector3.ZERO
@export var follow_speed: float = 15.0

# Resize window variables
var _resizing          := false
var _resize_handle     := ""
var _resize_start_hit  := Vector3.ZERO
var _resize_start_size := Vector2.ZERO
var _resize_start_pos  := Vector3.ZERO
var _resize_plane      := Plane()

# Size of the actual content, not the header
var content_size := Vector2(1.5, 0.75)  # match your QuadMesh default size
const HEADER_HEIGHT  : float = 0.08     # fixed header height in world units
const MIN_CONTENT_SIZE := Vector2(0.4, 0.2)
const MAX_CONTENT_SIZE := Vector2(3.0, 2.5)
const PIXELS_PER_UNIT : float = 150.0

func _ready() -> void:
	base_position = position

	var window_header: SWindowHeader = header_3d.get_scene_instance()
	window_header.close_pressed.connect(close)
	window_header.drag_started.connect(start_drag)
	window_header.drag_moved.connect(update_drag)
	window_header.drag_ended.connect(stop_drag)
	
	set_content(content)
	set_input_enabled(false)
	
	header_3d.pointer_event.connect(_on_pointer_event)
	content_3d.pointer_event.connect(_on_pointer_event)
	
	if not XRUtils.is_openxr_active():
		content_3d.set_process_input(false)
	_rebuild_resize_handles()
	

## Invoked when a pointer event on the window is detected
func _on_pointer_event(event: XRToolsPointerEvent):
	if event.event_type == XRToolsPointerEvent.Type.PRESSED:  # Focus this window when "pressed"
		focus()


## Send input event to this window
func send_input(event: InputEvent):
	content_3d._input(event)


## Sets the window's content to the given UI scene
func set_content(new_content: PackedScene) -> void:
	content_3d.set_scene(new_content)
	content = new_content


## Call this to tell the window manager to bring this window to front
func focus() -> void:
	on_focused.emit(self)
	
	
## Sets whether input events will be directed to this window
func set_input_enabled(enabled: bool) -> void:
	content_3d.input_keyboard = enabled
	content_3d.input_gamepad = enabled

## Updates the window's position based on its z-order
func apply_z_order() -> void:                                                                                    ##67 :)
	# move the window forward (toward the user) based on z_order
	position = base_position + Vector3(0, 0, z_order * Z_STEP)

## Visual feedback when the current window becomes the focused window
func set_focused_visual(is_focused: bool) -> void:
	var mat: StandardMaterial3D = $Header/Screen.material_override as StandardMaterial3D
	if not mat:
		return
	if is_focused:
		mat.albedo_color = Color(1.0, 1.0, 1.0, 1.0)
	else:
		mat.albedo_color = Color(0.6, 0.6, 0.6, 1.0)

# Called when the user grabs the header
func start_drag(hit_world: Vector3) -> void:
	_dragging = true
	_drag_offset = global_position - hit_world
	_drag_target = global_position
	base_position = global_position
	set_process(true)

# Called whenever the pointer moves while dragging
func update_drag(hit_world: Vector3) -> void:
	if not _dragging:
		return
	_drag_target = _clamp_to_bounds(hit_world + _drag_offset)
	_last_valid_hit = hit_world

func _process(delta: float) -> void:
	if not _dragging:
		return
	global_position = global_position.lerp(_drag_target, 1.0 - exp(-follow_speed * delta))
	base_position = global_position

# Called when the user releases controller
func stop_drag() -> void:
	_dragging = false
	set_process(false)

# Keeps the window within world bounds
func _clamp_to_bounds(pos: Vector3) -> Vector3:
	pos.x = clamp(pos.x, world_bounds.position.x, world_bounds.end.x)
	pos.y = clamp(pos.y, world_bounds.position.y, world_bounds.end.y)
	pos.z = clamp(pos.z, world_bounds.position.z, world_bounds.end.z)
	return pos

# Called when user grabs a resize handle
func start_resize(handle: String, hit_world: Vector3) -> void:
	_resizing          = true
	_resize_handle     = handle
	_resize_start_hit  = to_local(hit_world)
	_resize_start_size = content_size
	_resize_start_pos  = global_position
	# create a plane at the window's depth for smooth tracking
	var camera = get_viewport().get_camera_3d()
	if camera:
		var normal = (camera.global_position - global_position).normalized()
		_resize_plane = Plane(normal, global_position)
	set_process(true)

# Called every frame while resize handle is held
func update_resize(hit_world: Vector3) -> void:
	if not _resizing:
		return
	var delta := Vector2(
		to_local(hit_world).x - _resize_start_hit.x,
		to_local(hit_world).y - _resize_start_hit.y
	)
	var new_size := _resize_start_size
	var pos_shift := Vector2.ZERO

	if _resize_handle == "R":
		new_size.x += delta.x
	elif _resize_handle == "L":
		new_size.x -= delta.x
		pos_shift.x = delta.x / 2.0
	elif _resize_handle == "T":
		new_size.y += delta.y
	elif _resize_handle == "B":
		new_size.y -= delta.y
		pos_shift.y = delta.y / 2.0
	elif _resize_handle == "TR":
		new_size.x += delta.x
		new_size.y += delta.y
	elif _resize_handle == "TL":
		new_size.x -= delta.x
		new_size.y += delta.y
		pos_shift.x = delta.x / 2.0
	elif _resize_handle == "BR":
		new_size.x += delta.x
		new_size.y -= delta.y
		pos_shift.y = delta.y / 2.0
	elif _resize_handle == "BL":
		new_size.x -= delta.x
		new_size.y -= delta.y
		pos_shift = Vector2(delta.x / 2.0, delta.y / 2.0)

	var clamped := new_size.clamp(MIN_CONTENT_SIZE, MAX_CONTENT_SIZE)
	if clamped.is_equal_approx(new_size):
		global_position = _resize_start_pos + \
			global_transform.basis * Vector3(pos_shift.x, pos_shift.y, 0.0)
	_apply_content_size_mesh_only(clamped)

# Called when user releases resize handle
func stop_resize() -> void:
	_resizing      = false
	_resize_handle = ""
	# only update viewport resolution when done — expensive operation
	_update_content_viewport_resolution()
	_rebuild_resize_handles()
	set_process(false)

# Resize only the mesh while dragging — skip expensive viewport update
func _apply_content_size_mesh_only(new_size: Vector2) -> void:
	content_size = new_size.clamp(MIN_CONTENT_SIZE, MAX_CONTENT_SIZE)
	var content_mesh := content_3d.get_node("Screen") as MeshInstance3D
	if content_mesh and content_mesh.mesh is QuadMesh:
		(content_mesh.mesh as QuadMesh).size = content_size
	# reposition header to sit on top of content
	_reposition_header()

# Update the SubViewport resolution to match new size — only call when resize is done
func _update_content_viewport_resolution() -> void:
	var viewport := content_3d.get_node("Viewport") as SubViewport
	if viewport:
		viewport.size = Vector2i(
			int(content_size.x * PIXELS_PER_UNIT),
			int(content_size.y * PIXELS_PER_UNIT)
		)
	# also update collision shape
	var col := content_3d.get_node("StaticBody3D/CollisionShape3D") as CollisionShape3D
	if col and col.shape is BoxShape3D:
		(col.shape as BoxShape3D).size = Vector3(content_size.x, content_size.y, 0.02)

# Keeps the header sitting on top of the content area
func _reposition_header() -> void:
	var header_node := get_node("Header") as Node3D
	if header_node:
		header_node.position.y = (content_size.y / 2.0) + (HEADER_HEIGHT / 2.0)

# Create the handles for users to grab onto, only show when hovering near
func _rebuild_resize_handles() -> void:
	# remove old handles first
	var old = get_node_or_null("ResizeHandles")
	if old:
		remove_child(old)
		old.free()

	var root  = Node3D.new()
	root.name = "ResizeHandles"
	add_child(root)

	var hw := content_size.x / 2.0
	var hh := content_size.y / 2.0
	var t  := 0.08  # handle size in world units

	# handle id -> local position
	var handles := {
		"TL": Vector3(-hw,  hh, 0.01),
		"T":  Vector3(  0,  hh, 0.01),
		"TR": Vector3( hw,  hh, 0.01),
		"L":  Vector3(-hw,   0, 0.01),
		"R":  Vector3( hw,   0, 0.01),
		"BL": Vector3(-hw, -hh, 0.01),
		"B":  Vector3(  0, -hh, 0.01),
		"BR": Vector3( hw, -hh, 0.01),
	}

	for handle_id in handles:
		var area  = Area3D.new()
		var col   = CollisionShape3D.new()
		var shape = BoxShape3D.new()
		shape.size = Vector3(t, t, 0.05)
		col.shape  = shape
		area.add_child(col)
		area.position  = handles[handle_id]
		area.set_meta("handle_id", handle_id)
		root.add_child(area)
		# connect pointer events to this handle
		area.input_ray_pickable = true

# ── TEMP: mouse testing, delete when testing on headset ──────────────────────
var _drag_plane := Plane()

func _input(event: InputEvent) -> void:
	if not XRUtils.is_openxr_active():
		if event is InputEventMouseButton:
			if event.button_index == MOUSE_BUTTON_LEFT:
				if event.pressed:
					# check resize handles first, then fall back to drag
					if not _try_start_mouse_resize(event.position):
						_try_start_mouse_drag(event.position)
				else:
					if _resizing:
						stop_resize()
					else:
						stop_drag()
		elif event is InputEventMouseMotion:
			if _resizing:
				_update_mouse_resize(event.position)
			elif _dragging:
				_update_mouse_drag(event.position)

# Check if mouse clicked on a resize handle, returns true if resize started
func _try_start_mouse_resize(mouse_pos: Vector2) -> bool:
	var camera = get_viewport().get_camera_3d()
	if not camera:
		return false
	var ray_origin = camera.project_ray_origin(mouse_pos)
	var ray_dir    = camera.project_ray_normal(mouse_pos)
	var ray_end    = ray_origin + ray_dir * 20.0

	# use intersect_point on the space state to find overlapping areas
	var space = get_world_3d().direct_space_state
	
	# check Area3D handles using a separate query
	var params = PhysicsRayQueryParameters3D.create(ray_origin, ray_end)
	params.collision_mask = 0xFFFFFFFF  # hit everything
	params.collide_with_areas = true    # this is the key line — detect Area3D
	params.collide_with_bodies = false  # ignore regular bodies for this check
	
	var result = space.intersect_ray(params)
	if result.is_empty():
		return false
	
	var collider = result.collider
	if collider is Area3D and collider.has_meta("handle_id"):
		if _is_own_collider(collider):
			start_resize(collider.get_meta("handle_id"), result.position)
			return true
	return false

# Check if mouse clicked on this window's body, start dragging if so
func _try_start_mouse_drag(mouse_pos: Vector2) -> void:
	var camera = get_viewport().get_camera_3d()
	if not camera:
		return
	var ray_origin = camera.project_ray_origin(mouse_pos)
	var ray_dir    = camera.project_ray_normal(mouse_pos)
	var ray_end    = ray_origin + ray_dir * 20.0
	var params     = PhysicsRayQueryParameters3D.create(ray_origin, ray_end)
	var result     = get_world_3d().direct_space_state.intersect_ray(params)
	if result.is_empty():
		return
	if not _is_own_collider(result.collider):
		return
	# create a flat plane at the window's depth for smooth tracking
	var normal = (camera.global_position - global_position).normalized()
	_drag_plane = Plane(normal, global_position)
	start_drag(result.position)

# Move the window by tracking mouse against the drag plane
func _update_mouse_drag(mouse_pos: Vector2) -> void:
	var camera = get_viewport().get_camera_3d()
	if not camera:
		return
	var ray_origin = camera.project_ray_origin(mouse_pos)
	var ray_dir    = camera.project_ray_normal(mouse_pos)
	# plane never misses so movement is always smooth
	var hit = _drag_plane.intersects_ray(ray_origin, ray_dir)
	if hit:
		update_drag(hit)

# Resize the window by tracking mouse against the resize plane
func _update_mouse_resize(mouse_pos: Vector2) -> void:
	var camera = get_viewport().get_camera_3d()
	if not camera:
		return
	var ray_origin = camera.project_ray_origin(mouse_pos)
	var ray_dir    = camera.project_ray_normal(mouse_pos)
	var hit = _resize_plane.intersects_ray(ray_origin, ray_dir)
	if hit:
		update_resize(hit)

# Walk up the node tree to check if a collider belongs to this window
func _is_own_collider(collider: Object) -> bool:
	var current = collider as Node
	while current:
		if current == self:
			return true
		current = current.get_parent()
	return false
# ── END TEMP ──────────────────────────────────────────────────────────────────


## Self-cleaning function that destroys window content
func close() -> void:
	on_closed.emit()
	queue_free()
