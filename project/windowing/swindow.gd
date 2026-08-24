class_name SWindow extends Node3D

# Gesture code writes global_position while apply_z_order writes local position.
# These agree only while the WindowManager stays unrotated and unscaled: a
# RemoteTransform3D (root.tscn) drives it in position only, so locomotion
# translates it but never rotates or scales it, which keeps the mixed
# local-z / global-xy writes below safe.

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
const LAYER_ORIGIN_Z: float = -2.0

# Drag state variables
var _dragging    := false
var _drag_offset := Vector3.ZERO
var _drag_target := Vector3.ZERO
# Frozen at grab time so the window can't drift in depth. Accepted residual: an
# OUTSIDE z-order change mid-gesture (e.g. another window closing) leaves the
# frozen planes one z-step off until release, while window depth itself stays on
# the z_order grid.
var _drag_plane  := Plane()
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

# Grab bands straddling the content edges, keyed by handle id
var _resize_handles := {}
# Thickness tracks the window so a small one is not mostly handle, and stops
# growing once the band is comfortably wide enough to hit. Staying under half
# keeps the spans in _layout_resize_handles positive at MIN_CONTENT_SIZE.
const HANDLE_THICKNESS_RATIO := 0.15
const HANDLE_MAX_THICKNESS := 0.12
# Depth budget in window-local z, viewer on the +z side. A ray reports the
# nearest front face it enters, so the order of the faces is the order of picks:
#
#   -0.020 .. 0.000  own screen    XRToolsViewport2DIn3D hangs the box behind
#                                  the quad, so its front face is the plane at 0
#    0.000 .. 0.020  own handles   HANDLE_Z +/- HANDLE_DEPTH / 2
#    0.020 .. 0.030  empty
#    0.030 .. 0.050  next window's screen, starting at Z_STEP - SCREEN_DEPTH
#    0.050 .. 0.070  next window's handles
#
# Nothing overlaps; good.
const SCREEN_DEPTH := 0.02
const HANDLE_DEPTH := 0.02
const HANDLE_Z := 0.01
# Must intersect the controller raycasts' collision_mask in root.tscn
const HANDLE_COLLISION_LAYER := 4194304

# Size of the actual content, not the header. The literal is a placeholder.
var content_size := Vector2(1.5, 0.75)
const HEADER_HEIGHT  : float = 0.08     # fixed header height in world units
const MIN_CONTENT_SIZE := Vector2(0.4, 0.2)
const MAX_CONTENT_SIZE := Vector2(3.0, 2.5)
# Render density of each surface. Held constant across resizes so a bigger
# window buys more room rather than bigger content.
var PIXELS_PER_UNIT := 150.0
var HEADER_PIXELS_PER_UNIT := 150.0

# Live-resize resolution throttle. Reallocating a render target also relays out
# the 2D scene inside it, so committing every frame of a drag risks both a hitch
# and a visible re-wrap. MAX_STRETCH does the real saving by bounding how far the
# targets may lag the quads; the interval is only a ceiling on commit rate.
const MAX_STRETCH := 0.03
const MIN_COMMIT_INTERVAL := 1.0 / 15.0
# Content size the current render targets were allocated for
var _res_basis := Vector2.ZERO
var _res_pending := false
var _since_commit := 0.0

func _ready() -> void:
	var window_header: SWindowHeader = header_3d.get_scene_instance()
	window_header.close_pressed.connect(close)

	set_content(content)
	set_input_enabled(false)

	header_3d.pointer_event.connect(_on_pointer_event)
	header_3d.pointer_event.connect(_on_header_pointer_event)
	content_3d.pointer_event.connect(_on_pointer_event)

	# Seed from the authored scene, not from the script defaults above, so the
	# two cannot silently disagree.
	content_size = content_3d.screen_size
	PIXELS_PER_UNIT = content_3d.viewport_size.x / (0.00001 + content_3d.screen_size.x)
	HEADER_PIXELS_PER_UNIT = header_3d.viewport_size.x / (0.00001 + header_3d.screen_size.x)

	if not XRUtils.is_openxr_active():
		header_3d.enabled = true
		content_3d.set_process_input(false)
	_build_resize_handles()
	_apply_size(content_size)


## Focuses the window on any press, whichever surface the pointer hit.
func _on_pointer_event(event: XRToolsPointerEvent):
	if event.event_type == XRToolsPointerEvent.Type.PRESSED:
		focus()


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


## Intersects the pointer that raised `event` with `plane`. Returns the hit as a
## Vector3, or null when the ray misses the plane this frame. Compare the result
## with `!= null`, not truthiness — Vector3.ZERO is falsy.
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


## Requests focus for this window; the window manager performs the reorder.
func focus() -> void:
	on_focused.emit(self)


## Sets whether input events will be directed to this window
func set_input_enabled(enabled: bool) -> void:
	content_3d.input_keyboard = enabled
	content_3d.input_gamepad = enabled

## Places the window at the depth its z_order calls for, leaving XY untouched.
func apply_z_order() -> void:
	# Derived from z_order alone, never from the current position, so repeated
	# reorders cannot let depth drift off the Z_STEP grid
	position.z = LAYER_ORIGIN_Z + z_order * Z_STEP

## Dims the header while the window is not the focused one.
func set_focused_visual(is_focused: bool) -> void:
	var mat: StandardMaterial3D = $Header/Screen.material_override as StandardMaterial3D
	if not mat:
		return
	if is_focused:
		mat.albedo_color = Color(1.0, 1.0, 1.0, 1.0)
	else:
		mat.albedo_color = Color(0.6, 0.6, 0.6, 1.0)

## The window's facing plane at its current depth. Assumes the window is
## XY-axis-aligned.
func _get_plane() -> Plane:
	return Plane(Vector3(0, 0, 1), global_position)

## Starts a header drag from the grab described by `event`. No-op when the
## pointer ray misses the window's plane.
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

## Retargets the in-flight drag to `hit_world`, clamped to world bounds. No-op
## when no drag is in flight.
func update_drag(hit_world: Vector3) -> void:
	if not _dragging:
		return
	_drag_target = _clamp_to_bounds(hit_world + _drag_offset)

func _process(delta: float) -> void:
	# Driven on a clock, not from update_resize, so a drag that stops moving
	# without releasing still catches its resolution up
	if _resizing:
		_tick_resolution(delta)

	if not _dragging:
		return

	# Drag moves the window in XY only; z stays owned by z_order so a mid-drag
	# stack change (focus, window close) can't pull depth off the grid.
	var next := global_position.lerp(_drag_target, 1.0 - exp(-follow_speed * delta))
	global_position.x = next.x
	global_position.y = next.y

## Ends the drag, leaving the window wherever it settled.
func stop_drag() -> void:
	_dragging = false
	# The other gesture may still need the tick
	set_process(_resizing)

## `pos` clamped into world_bounds on X and Y; Z is passed through untouched.
func _clamp_to_bounds(pos: Vector3) -> Vector3:
	pos.x = clamp(pos.x, world_bounds.position.x, world_bounds.end.x)
	pos.y = clamp(pos.y, world_bounds.position.y, world_bounds.end.y)
	return pos

## Starts a resize on `handle` ("L", "R", "B", "BL" or "BR") from the grab
## described by `event`. No-op when the pointer ray misses the window's plane.
func start_resize(handle: String, event: XRToolsPointerEvent) -> void:
	# Freeze the gesture plane after focusing (focus can raise the window by
	# n*Z_STEP) and resolve the baseline against that same plane, so the
	# baseline and later MOVED frames agree.
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
	set_process(true)


## Resizes the window to follow the pointer at `hit_world`, keeping the edges
## the grabbed handle does not own pinned. No-op when no resize is in flight.
func update_resize(hit_world: Vector3) -> void:
	if not _resizing:
		return
	# NOTE: Assumes window is unrotated (world XY == window XY)
	var delta := Vector2(
		hit_world.x - _resize_start_hit.x,
		hit_world.y - _resize_start_hit.y
	)
	var new_size := _resize_start_size
	# The screens are centred on the window, so a size change alone walks both
	# edges outward by half of it. Every handle therefore also shifts the window
	# by that same half, which is what pins the edge opposite the one grabbed.
	# This sign maps that size change to the shift's direction: +1 on an axis
	# whose positive edge the handle owns.
	var shift_sign := Vector2.ZERO

	if _resize_handle == "R":
		new_size.x += delta.x
		shift_sign.x = 1.0
	elif _resize_handle == "L":
		new_size.x -= delta.x
		shift_sign.x = -1.0
	elif _resize_handle == "B":
		new_size.y -= delta.y
		shift_sign.y = -1.0
	elif _resize_handle == "BR":
		new_size.x += delta.x
		new_size.y -= delta.y
		shift_sign = Vector2(1.0, -1.0)
	elif _resize_handle == "BL":
		new_size.x -= delta.x
		new_size.y -= delta.y
		shift_sign = Vector2(-1.0, -1.0)

	var clamped := new_size.clamp(MIN_CONTENT_SIZE, MAX_CONTENT_SIZE)
	# Measured against the size actually applied, not the pointer delta: past a
	# clamp the pointer keeps moving while the size does not, and a shift still
	# tracking the pointer would drag the pinned edge along with it.
	var pos_shift := (clamped - _resize_start_size) * shift_sign / 2.0
	# Apply the shift in XY only; z stays owned by z_order so a stale
	# _resize_start_pos.z can't leak back in after a mid-resize stack change.
	# NOTE: Assumes window is unrotated (basis maps XY shift to world XY).
	var shifted := _resize_start_pos + \
		global_transform.basis * Vector3(pos_shift.x, pos_shift.y, 0.0)
	global_position.x = shifted.x
	global_position.y = shifted.y
	_apply_size(clamped, true)


## Ends the resize and settles the render resolutions at the final size.
func stop_resize() -> void:
	_resizing      = false
	_resize_handle = ""
	set_process(_dragging)
	# Gesture over: settle exactly, whatever the throttle last committed
	_apply_size(content_size)


## Resizes the window's content to `new_size`, clamped to MIN/MAX_CONTENT_SIZE,
## and brings the header and both screens' geometry with it.
##
## Sole writer of size state. `live` omits the render resolutions; the caller
## must call again without it to settle them.
func _apply_size(new_size: Vector2, live: bool = false) -> void:
	content_size = new_size.clamp(MIN_CONTENT_SIZE, MAX_CONTENT_SIZE)
	var header_size := Vector2(content_size.x, HEADER_HEIGHT)

	# Assigning screen_size drives the quad, the static body's translator and
	# the collision shape as one, so they cannot disagree mid-gesture.
	content_3d.screen_size = content_size
	header_3d.screen_size = header_size
	# Header sits on top of the content; both are centred on the window
	header_3d.position.y = (content_size.y + HEADER_HEIGHT) / 2.0
	_layout_resize_handles()

	if live:
		_res_pending = true
		return

	_commit_resolution()


## Reallocates both render targets so each surface renders at its authored
## pixel density for the current content size.
func _commit_resolution() -> void:
	var header_size := Vector2(content_size.x, HEADER_HEIGHT)
	content_3d.viewport_size = _viewport_resolution(content_size, PIXELS_PER_UNIT)
	header_3d.viewport_size = _viewport_resolution(header_size, HEADER_PIXELS_PER_UNIT)
	# Resizing a render target clears it, and the addon only re-arms the refill
	# on its own throttle clock, which runs at an unrelated phase to this one —
	# leaving the target blank long enough to read as a flash. Re-arm it here,
	# on exactly the frames that reallocate.
	_request_redraw(content_3d)
	_request_redraw(header_3d)
	_res_basis = content_size
	_res_pending = false
	_since_commit = 0.0


## Asks `surface` to redraw its viewport once on the coming frame.
func _request_redraw(surface: XRToolsViewport2DIn3D) -> void:
	var viewport := surface.get_node("Viewport") as SubViewport
	# Assign unconditionally: the renderer resets its own copy after drawing and
	# never writes back here, so skipping the write when the property already
	# reads UPDATE_ONCE would skip the redraw
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


## Advances the throttle clock and commits a pending resolution once both the
## stretch and interval gates allow it.
func _tick_resolution(delta: float) -> void:
	_since_commit += delta
	if not _res_pending or _since_commit < MIN_COMMIT_INTERVAL:
		return
	# Below the tolerance a reallocation would cost more than the blur it fixes,
	# so the update stays pending until the drag earns it or stop_resize settles it
	if not _stretch_exceeded():
		return
	_commit_resolution()


## True when either axis of the render targets is more than MAX_STRETCH away
## from the size it is currently being displayed at.
func _stretch_exceeded() -> bool:
	if _res_basis.x <= 0.0 or _res_basis.y <= 0.0:
		return true
	return absf(content_size.x / _res_basis.x - 1.0) > MAX_STRETCH \
			or absf(content_size.y / _res_basis.y - 1.0) > MAX_STRETCH


## Render resolution for a screen of `size` world units at `ppu` pixels per
## unit, rounded, never smaller than one pixel on either axis.
func _viewport_resolution(size: Vector2, ppu: float) -> Vector2:
	# A zero-sized viewport is invalid, so the floor is a hard requirement
	return Vector2(maxf(1.0, roundf(size.x * ppu)), maxf(1.0, roundf(size.y * ppu)))


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

## Creates the five resize handle bodies under "ResizeHandles". Call once.
func _build_resize_handles() -> void:
	var root := Node3D.new()
	root.name = "ResizeHandles"
	add_child(root)

	for handle_id in ["L", "R", "B", "BL", "BR"]:
		var body := StaticBody3D.new()
		body.name = "Handle" + handle_id
		# The controller raycasts leave collide_with_areas off and test only
		# their own mask, so a handle has to be a body on that layer to be hit
		body.collision_layer = HANDLE_COLLISION_LAYER
		body.collision_mask = 0
		body.set_meta("handle_id", handle_id)

		var col := CollisionShape3D.new()
		col.shape = BoxShape3D.new()
		body.add_child(col)

		# HandPointer emits this on whichever collider its ray landed on
		body.add_user_signal("pointer_event")
		body.connect("pointer_event",
				func(event: XRToolsPointerEvent) -> void:
					_on_handle_pointer_event(handle_id, event))

		root.add_child(body)
		_resize_handles[handle_id] = body

	_layout_resize_handles()


## Sizes and positions the handles to straddle the current content edges.
func _layout_resize_handles() -> void:
	var hw := content_size.x / 2.0
	var hh := content_size.y / 2.0
	var tx := minf(HANDLE_MAX_THICKNESS, content_size.x * HANDLE_THICKNESS_RATIO)
	var ty := minf(HANDLE_MAX_THICKNESS, content_size.y * HANDLE_THICKNESS_RATIO)

	# Each band is centred on its edge, so it reaches half its thickness outside
	# the window and covers only half of it in content
	var x_outer_l := -hw - tx / 2.0
	var x_inner_l := -hw + tx / 2.0
	var x_inner_r := hw - tx / 2.0
	var x_outer_r := hw + tx / 2.0
	var y_outer_b := -hh - ty / 2.0
	var y_inner_b := -hh + ty / 2.0

	# The corners take a whole band at each end of the border and the edges span
	# exactly what is left, so the five tile it: no gap to fall through, and no
	# overlap for a ray to have to resolve between equal depths. There is no top
	# edge or top corner because the header owns that side.
	_place_handle("BL", Vector2(x_outer_l, y_outer_b), Vector2(x_inner_l, y_inner_b))
	_place_handle("BR", Vector2(x_inner_r, y_outer_b), Vector2(x_outer_r, y_inner_b))
	_place_handle("B", Vector2(x_inner_l, y_outer_b), Vector2(x_inner_r, y_inner_b))
	_place_handle("L", Vector2(x_outer_l, y_inner_b), Vector2(x_inner_l, hh))
	_place_handle("R", Vector2(x_inner_r, y_inner_b), Vector2(x_outer_r, hh))


## Covers the content-local rect from corner `lo` to corner `hi` with the handle
## `handle_id`, at the depth all handles share.
func _place_handle(handle_id: String, lo: Vector2, hi: Vector2) -> void:
	var body: StaticBody3D = _resize_handles[handle_id]
	body.position = Vector3((lo.x + hi.x) / 2.0, (lo.y + hi.y) / 2.0, HANDLE_Z)
	var col := body.get_child(0) as CollisionShape3D
	(col.shape as BoxShape3D).size = Vector3(hi.x - lo.x, hi.y - lo.y, HANDLE_DEPTH)


## Closes the window: emits on_closed and frees the node.
func close() -> void:
	# Cancel any in-flight gesture so a missed RELEASED can't leave stale state
	_dragging = false
	_resizing = false
	set_process(false)
	on_closed.emit()
	queue_free()
