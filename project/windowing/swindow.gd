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

## Shared depth baseline for z-order level 0 (in meters).
## World z is always LAYER_ORIGIN_Z + z_order * Z_STEP — never derived from
## positions — so depth cannot drift off the Z_STEP grid.
const LAYER_ORIGIN_Z: float = -2.0

# Drag state variables
var _dragging    := false
var _drag_offset := Vector3.ZERO
var _drag_target := Vector3.ZERO
var _drag_plane  := Plane()  # frozen at grab time so the window can't drift in depth
var world_bounds := AABB(Vector3(-3, 0.5, -1.5), Vector3(6, 3, 0)) #update as needed
@export var follow_speed: float = 30.0

# Resize window variables
var _resizing          := false
var _resize_handle     := ""
# World-space grab point; deltas are measured in world space because the
# window itself moves during L/B resizes — measuring in the live local frame
# would feed the position shift back into the measurement (edge tracks only
# 2/3 of pointer motion and oscillates)
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

# NOTE: Gesture code uses global_position while apply_z_order sets local
# position — equivalent only while the WindowManager sits at the world origin,
# unrotated and unscaled.
func _ready() -> void:
	var window_header: SWindowHeader = header_3d.get_scene_instance()
	window_header.close_pressed.connect(close)
	
	set_content(content)
	set_input_enabled(false)
	
	header_3d.pointer_event.connect(_on_pointer_event)
	header_3d.pointer_event.connect(_on_header_pointer_event)
	content_3d.pointer_event.connect(_on_pointer_event)
	content_3d.pointer_event.connect(_on_content_pointer_event)
	
	if not XRUtils.is_openxr_active():
		header_3d.enabled = true
		content_3d.set_process_input(false)
	_rebuild_resize_handles()
	

## Invoked when a pointer event on the window is detected
func _on_pointer_event(event: XRToolsPointerEvent):
	if event.event_type == XRToolsPointerEvent.Type.PRESSED:  # Focus this window when "pressed"
		# print("(before focus) [%s] z=%.5f" % [name, global_position.z])
		focus()
		# print("(after focus) [%s] z=%.5f" % [name, global_position.z])


func _on_header_pointer_event(event: XRToolsPointerEvent):
	match event.event_type:
		XRToolsPointerEvent.Type.PRESSED:
			start_drag(event)
		XRToolsPointerEvent.Type.MOVED:
			var hit = _resolve_pointer_hit(event, _drag_plane)
			if hit != null:
				update_drag(hit)
		XRToolsPointerEvent.Type.RELEASED:
			stop_drag()
		_:
			pass


## Re-intersects the pointer ray against the frozen gesture plane.
## Returns the on-plane hit as a Vector3, or null when the ray misses the
## plane this frame (caller should skip the frame). Compare with `!= null`,
## not truthiness — Vector3.ZERO is falsy.
func _resolve_pointer_hit(event: XRToolsPointerEvent, plane: Plane) -> Variant:
	var hand := event.pointer as HandPointer
	if not hand:
		# Non-hand pointers (e.g. simulator): keep XY, snap depth to the plane
		return plane.project(event.position)
	return plane.intersects_ray(hand.get_ray_origin(), hand.get_ray_direction())


## Send input event to this window
func send_input(event: InputEvent):
	content_3d._input(event)


## Sets the window's content to the given UI scene
func set_content(new_content: PackedScene) -> void:
	content_3d.set_scene(new_content)
	content = new_content


## Sets this window as focused
func focus() -> void:
	on_focused.emit(self)
	
	
## Sets whether input events will be directed to this window
func set_input_enabled(enabled: bool) -> void:
	content_3d.input_keyboard = enabled
	content_3d.input_gamepad = enabled

## Updates the window's depth based on its z-order
func apply_z_order() -> void:
	# depth comes exclusively from z_order; XY is left untouched
	position.z = LAYER_ORIGIN_Z + z_order * Z_STEP

## Visual feedback when the current window becomes the focused window
func set_focused_visual(is_focused: bool) -> void:
	var mat: StandardMaterial3D = $Header/Screen.material_override as StandardMaterial3D
	if not mat:
		return
	if is_focused:
		mat.albedo_color = Color(1.0, 1.0, 1.0, 1.0)
	else:
		mat.albedo_color = Color(0.6, 0.6, 0.6, 1.0)

## Retrieves the plane aligned with the window
func _get_plane() -> Plane:
	return Plane(Vector3(0, 0, 1), global_position)  # NOTE: Assumes window XY-axis-aligned

## Called when the user grabs the header
func start_drag(event: XRToolsPointerEvent) -> void:
	# Focus first: it can raise the window by n*Z_STEP, so the gesture plane
	# must be frozen at the NEW depth. The baseline is then resolved against
	# that same plane — never event.position, which sits on the pre-focus
	# plane and would pop the window sideways on the first MOVED frame.
	focus()
	_drag_plane = _get_plane()
	var hit = _resolve_pointer_hit(event, _drag_plane)
	if hit == null:
		return
	_dragging = true
	_drag_offset = global_position - hit
	_drag_offset.z = 0.0
	_drag_target = global_position
	set_process(true)
	print("[%s] drag start z=%.5f" % [name, global_position.z])

## Called whenever the pointer moves while dragging
func update_drag(hit_world: Vector3) -> void:
	if not _dragging:
		return
	_drag_target = _clamp_to_bounds(hit_world + _drag_offset)

func _process(delta: float) -> void:
	if not _dragging:
		return

	# Drag moves the window in XY only; z stays owned by z_order so a mid-drag
	# stack change (focus, window close) can't pull depth off the grid.
	var next := global_position.lerp(_drag_target, 1.0 - exp(-follow_speed * delta))
	global_position.x = next.x
	global_position.y = next.y

# Called when the user releases controller
func stop_drag() -> void:
	_dragging = false
	set_process(false)
	print("[%s] drag end z=%.5f" % [name, global_position.z])

## Keeps the window within world bounds
func _clamp_to_bounds(pos: Vector3) -> Vector3:
	pos.x = clamp(pos.x, world_bounds.position.x, world_bounds.end.x)
	pos.y = clamp(pos.y, world_bounds.position.y, world_bounds.end.y)
	return pos

## Called when user grabs a resize handle
func start_resize(handle: String, event: XRToolsPointerEvent) -> void:
	# Same plane discipline as start_drag: freeze the plane post-focus and
	# resolve the baseline against it so baseline and MOVED frames agree.
	focus()
	_resize_plane = _get_plane()
	var hit = _resolve_pointer_hit(event, _resize_plane)
	if hit == null:
		return
	_resizing          = true
	_resize_handle     = handle
	_resize_start_hit  = hit
	_resize_start_size = content_size
	_resize_start_pos  = global_position
	print("[%s] resize start z=%.5f" % [name, global_position.z])


## Called every frame while resize handle is held
func update_resize(hit_world: Vector3) -> void:
	if not _resizing:
		return
	# NOTE: Assumes window is unrotated (world XY == window XY)
	var delta := Vector2(
		hit_world.x - _resize_start_hit.x,
		hit_world.y - _resize_start_hit.y
	)
	var new_size := _resize_start_size
	var pos_shift := Vector2.ZERO

	if _resize_handle == "R":
		new_size.x += delta.x
	elif _resize_handle == "L":
		new_size.x -= delta.x
		pos_shift.x = delta.x / 2.0
	elif _resize_handle == "B":
		new_size.y -= delta.y
		pos_shift.y = delta.y / 2.0
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
		# Apply the shift in XY only; z stays owned by z_order so a stale
		# _resize_start_pos.z can't leak back in after a mid-resize stack change.
		# NOTE: Assumes window is unrotated (basis maps XY shift to world XY).
		var shifted := _resize_start_pos + \
			global_transform.basis * Vector3(pos_shift.x, pos_shift.y, 0.0)
		global_position.x = shifted.x
		global_position.y = shifted.y
	_apply_content_size_mesh_only(clamped)


## Called when user releases resize handle
func stop_resize() -> void:
	_resizing      = false
	_resize_handle = ""
	# only update viewport resolution when done - expensive operation
	_update_content_viewport_resolution()
	_rebuild_resize_handles()
	print("[%s] resize stops z=%.5f" % [name, global_position.z])


## Resize the content mesh without updating viewport
func _apply_content_size_mesh_only(new_size: Vector2) -> void:
	content_size = new_size.clamp(MIN_CONTENT_SIZE, MAX_CONTENT_SIZE)
	var content_mesh := content_3d.get_node("Screen") as MeshInstance3D
	if content_mesh and content_mesh.mesh is QuadMesh:
		(content_mesh.mesh as QuadMesh).size = content_size
	# reposition header to sit on top of content
	_reposition_header()

## Update content viewport resolution to match content mesh size
func _update_content_viewport_resolution() -> void:
	var viewport := content_3d.get_node("Viewport") as SubViewport
	if viewport:
		viewport.size = Vector2i(
			int(content_size.x * PIXELS_PER_UNIT),
			int(content_size.y * PIXELS_PER_UNIT)
		)
	var col := content_3d.get_node("StaticBody3D/CollisionShape3D") as CollisionShape3D
	if col and col.shape is BoxShape3D:
		(col.shape as BoxShape3D).size = Vector3(content_size.x, content_size.y, 0.02)

## Keeps the header sitting on top of the content area
func _reposition_header() -> void:
	var header_node := get_node("Header") as Node3D
	if header_node:
		header_node.position.y = (content_size.y / 2.0) + (HEADER_HEIGHT / 2.0)


## Invoked when a resize handle's pointer event signal is received
func _on_handle_pointer_event(handle_id: String, event: XRToolsPointerEvent) -> void:
	match event.event_type:
		XRToolsPointerEvent.Type.PRESSED:
			start_resize(handle_id, event)
		XRToolsPointerEvent.Type.MOVED:
			var hit = _resolve_pointer_hit(event, _resize_plane)
			if hit != null:
				update_resize(hit)
		XRToolsPointerEvent.Type.RELEASED:
			stop_resize()
		_:
			pass

## Invoked on content pointer event
func _on_content_pointer_event(event: XRToolsPointerEvent) -> void:
	match event.event_type:
		XRToolsPointerEvent.Type.PRESSED:
			var handle = _get_handle_from_world_pos(event.position)
			if handle != "":
				# pointer is near an edge — start resize
				start_resize(handle, event)
		XRToolsPointerEvent.Type.MOVED:
			if _resizing:
				var hit = _resolve_pointer_hit(event, _resize_plane)
				if hit != null:
					update_resize(hit)
		XRToolsPointerEvent.Type.RELEASED:
			if _resizing:
				stop_resize()
		_:
			pass

## Determines resize handle from pointer world position
func _get_handle_from_world_pos(world_pos: Vector3) -> String:
	# convert world position to local position relative to content
	var local = content_3d.to_local(world_pos)
	var hw := content_size.x / 2.0
	var hh := content_size.y / 2.0
	# edge threshold — how close to the edge counts as a resize handle
	var edge := 0.12

	var on_left   : bool = local.x < -hw + edge
	var on_right  : bool = local.x >  hw - edge
	var on_bottom : bool = local.y < -hh + edge

	if on_bottom and on_left:  return "BL"
	if on_bottom and on_right: return "BR"
	if on_left:                return "L"
	if on_right:               return "R"
	if on_bottom:              return "B"
	return ""


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
		area.collision_layer = 0
		area.set_meta("handle_id", handle_id)
		if not area.has_user_signal("pointer_event"):
			area.add_user_signal("pointer_event")
		# assert(area.has_signal("pointer_event")) #TEMP: remove after passes
		area.connect("pointer_event", func(event: XRToolsPointerEvent): _on_handle_pointer_event(handle_id, event))
		root.add_child(area)
		# connect pointer events to this handle
		area.input_ray_pickable = true



## Self-cleaning function that destroys window content
func close() -> void:
	# cancel any in-flight gesture so a missed RELEASED can't leave stale state
	_dragging = false
	_resizing = false
	set_process(false)
	on_closed.emit()
	queue_free()
