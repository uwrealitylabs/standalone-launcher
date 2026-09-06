class_name SWindow extends Node3D

# The WindowManager owns this window's placement: it parents the window under the
# identity WindowLayer and writes its local transform from the assigned slot. The
# window never writes its own position; a resize keeps the content centre fixed.

@export_group("Content")
@export var content: PackedScene

@export_group("References")
@export var header_3d: XRToolsViewport2DIn3D
@export var content_3d: XRToolsViewport2DIn3D

signal on_closed()
signal on_focused(win: SWindow)

# The manager that owns this window's placement and size policy. Null for a
# standalone window (e.g. a headless test fixture), which falls back to the
# numeric clamp below.
var manager: WindowManager = null

# Resize window variables
var _resizing          := false
var _resize_handle     := ""
# The grab point and the window's frame are frozen at gesture start so a resize
# is rotation-safe and fixed-centre: the origin never moves, both edges grow
# symmetrically about it, and pointer displacement is projected onto the frozen
# world axes rather than assuming world XY.
var _resize_start_hit  := Vector3.ZERO
var _resize_start_size := Vector2.ZERO
var _resize_x_axis     := Vector3.RIGHT
var _resize_y_axis     := Vector3.UP
var _resize_plane      := Plane()
# The permutation-safe width cap, frozen at gesture start. The manager reads it
# through clamp_content_size while _resizing so mid-gesture frames need no rescan.
var _resize_max_width  := MAX_CONTENT_SIZE.x

# Grab bands straddling the content edges, keyed by handle id
var _resize_handles := {}
# Unshaded white marks hinting where each handle is, keyed by handle id. Shown
# while a ray hovers a handle and hidden when it leaves, resize or not. These are
# pure visuals: no collision, so they never interfere with handle picking.
var _resize_affordances := {}
# Nominal length of a mark along its edge, capped to a fraction of that edge so
# the two bottom corners never overlap and a mark never spans its whole side.
const AFFORDANCE_LENGTH := 0.12
const AFFORDANCE_THICKNESS := 0.006
# In front of the handle bodies (viewer on +z) so the marks never Z-fight the
# screen or the collision boxes.
const AFFORDANCE_Z := HANDLE_Z + HANDLE_DEPTH / 2.0 + 0.001
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
#
# The screen sits behind the handles, so grabbing an edge never picks the screen.
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
	_build_resize_affordances()
	_apply_size(content_size)


## Focuses the window on any press, whichever surface the pointer hit.
func _on_pointer_event(event: XRToolsPointerEvent):
	if event.event_type == XRToolsPointerEvent.Type.PRESSED:
		focus()


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


## Sets whether input events will be directed to this window, and tells the
## content scene, if it defines on_window_focus_changed(bool), that focus moved.
func set_input_enabled(enabled: bool) -> void:
	content_3d.input_keyboard = enabled
	content_3d.input_gamepad = enabled
	# The header is gated for keys too, or every window's title bar would keep
	# taking physical ones no matter which window is being typed into. Its
	# gamepad flag is left as authored, which is off.
	header_3d.input_keyboard = enabled

	# The scene is set after the first focus call, so early on there is nothing
	# to notify yet -- content_3d reports null until then.
	var scene := content_3d.get_scene_instance()
	if scene and scene.has_method("on_window_focus_changed"):
		scene.on_window_focus_changed(enabled)

## Dims the header while the window is not the focused one.
func set_focused_visual(is_focused: bool) -> void:
	var mat: StandardMaterial3D = $Header/Screen.material_override as StandardMaterial3D
	if not mat:
		return
	if is_focused:
		mat.albedo_color = Color(1.0, 1.0, 1.0, 1.0)
	else:
		mat.albedo_color = Color(0.6, 0.6, 0.6, 1.0)

func _process(delta: float) -> void:
	# Driven on a clock, not from update_resize, so a resize that stops moving
	# without releasing still catches its resolution up.
	if _resizing:
		_tick_resolution(delta)

## Starts a resize on `handle` ("L", "R", "B", "BL" or "BR") from the grab
## described by `event`. No-op when the pointer ray misses the window's plane.
func start_resize(handle: String, event: XRToolsPointerEvent) -> void:
	# Focus first, then freeze the whole gesture frame. The plane faces along the
	# window normal and passes through the handle collider's depth centre (not the
	# window origin), so the grab lands where the handle actually is. Resolving
	# the baseline against this same frozen plane keeps it consistent with the
	# MOVED frames that follow.
	focus()
	var xf := global_transform.orthonormalized()
	_resize_plane = Plane(xf.basis.z, xf.origin + xf.basis.z * HANDLE_Z)
	var hit = _resolve_pointer_hit(event, _resize_plane)
	if hit == null:
		return
	# Take exclusive resize ownership before freezing any gesture state; a refusal
	# (another window is already resizing) leaves this window untouched.
	if manager and not manager.acquire_resize(self):
		return
	_resizing          = true
	_resize_handle     = handle
	_resize_start_hit  = hit
	_resize_start_size = content_size
	# Freeze the width cap for the whole gesture: exclusive ownership means no other
	# window's width changes, so this cap stays valid until release.
	_resize_max_width  = manager.max_content_width_for(self) if manager else MAX_CONTENT_SIZE.x
	# Cache the world axes so displacement is measured in the window's own frame
	# regardless of yaw. The origin is never cached: a resize never moves it.
	_resize_x_axis     = xf.basis.x
	_resize_y_axis     = xf.basis.y
	set_process(true)


## Resizes the window to follow the pointer at `hit_world`, keeping the content
## centre fixed and growing symmetrically. No-op when no resize is in flight.
func update_resize(hit_world: Vector3) -> void:
	if not _resizing:
		return
	# Project the displacement onto the frozen world axes, then apply the
	# fixed-centre rule: the grabbed edge follows the pointer while the opposite
	# edge moves by the same amount, so the dimension changes by twice the
	# projected displacement. All requests go through resize() so the managed
	# clamp cannot be bypassed.
	var d := hit_world - _resize_start_hit
	var dx := d.dot(_resize_x_axis)
	var dy := d.dot(_resize_y_axis)
	var dw := 0.0
	var dh := 0.0
	match _resize_handle:
		"R":
			dw = 2.0 * dx
		"L":
			dw = -2.0 * dx
		"B":
			dh = -2.0 * dy
		"BR":
			dw = 2.0 * dx
			dh = -2.0 * dy
		"BL":
			dw = -2.0 * dx
			dh = -2.0 * dy

	resize(_resize_start_size + Vector2(dw, dh), true)


## Ends the resize and settles the render resolutions at the final size.
func stop_resize() -> void:
	_resizing      = false
	# The mark is driven purely by hover, so it is left as-is here: still shown if
	# the ray is on the handle, and cleared later by the handle's own EXITED.
	_resize_handle = ""
	if manager:
		manager.release_resize(self)
	set_process(false)
	# Gesture over: settle exactly, whatever the throttle last committed
	_apply_size(content_size)


## Resizes the window's content to `desired`. All managed size requests route
## through the manager's clamp so no caller can bypass the layout's size policy;
## a standalone window falls back to the numeric clamp. `live` omits the render
## resolutions, as in [method _apply_size].
func resize(desired: Vector2, live: bool = false) -> void:
	var clamped: Vector2
	if manager:
		clamped = manager.clamp_content_size(self, desired)
	else:
		clamped = desired.clamp(MIN_CONTENT_SIZE, MAX_CONTENT_SIZE)
	_apply_size(clamped, live)


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
	_layout_resize_affordances()

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
		XRToolsPointerEvent.Type.ENTERED:
			_set_affordance_visible(handle_id, true)
		XRToolsPointerEvent.Type.EXITED:
			_set_affordance_visible(handle_id, false)
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


## Creates the affordance marks under "ResizeAffordances", one hidden group per
## handle. Edge handles carry a single segment; the bottom corners carry two arms
## meeting at the corner. Call once, after the handles exist.
func _build_resize_affordances() -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color.WHITE
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	var root := Node3D.new()
	root.name = "ResizeAffordances"
	add_child(root)

	# Edge marks are one segment; each bottom corner is two arms. No top mark:
	# the header owns that side and it has no handle.
	var segment_counts := {"L": 1, "R": 1, "B": 1, "BL": 2, "BR": 2}
	for handle_id in segment_counts:
		var group := Node3D.new()
		group.name = "Affordance" + handle_id
		group.visible = false
		for _i in segment_counts[handle_id]:
			group.add_child(_make_affordance_segment(mat))
		root.add_child(group)
		_resize_affordances[handle_id] = group

	_layout_resize_affordances()


## A thin unshaded box with no collision, used as one affordance segment.
func _make_affordance_segment(mat: StandardMaterial3D) -> MeshInstance3D:
	var seg := MeshInstance3D.new()
	seg.mesh = BoxMesh.new()
	seg.material_override = mat
	return seg


## Positions the affordance marks over the current content edges, mirroring the
## handle layout. No-op until the marks are built.
func _layout_resize_affordances() -> void:
	if _resize_affordances.is_empty():
		return
	var hw := content_size.x / 2.0
	var hh := content_size.y / 2.0
	var t := AFFORDANCE_THICKNESS
	# Cap each mark to a fraction of its edge so the two bottom corners never
	# overlap and no mark spans a whole side.
	var len_x := minf(AFFORDANCE_LENGTH, content_size.x * 0.4)
	var len_y := minf(AFFORDANCE_LENGTH, content_size.y * 0.4)

	# Edge marks: centred on each side, none on top.
	_place_segment(_resize_affordances["L"].get_child(0),
			Vector3(-hw, 0.0, AFFORDANCE_Z), Vector3(t, len_y, t))
	_place_segment(_resize_affordances["R"].get_child(0),
			Vector3(hw, 0.0, AFFORDANCE_Z), Vector3(t, len_y, t))
	_place_segment(_resize_affordances["B"].get_child(0),
			Vector3(0.0, -hh, AFFORDANCE_Z), Vector3(len_x, t, t))

	# Corner marks: a horizontal arm and a vertical arm meeting at each bottom
	# corner. A signed arm length carries the direction it grows from the corner.
	_layout_corner("BL", -hw, -hh, len_x, len_y, t)
	_layout_corner("BR", hw, -hh, -len_x, len_y, t)


## Lays out one corner mark: a horizontal arm of signed length `arm_x` and a
## vertical arm of signed length `arm_y`, both growing from the corner (cx, cy).
func _layout_corner(handle_id: String, cx: float, cy: float,
		arm_x: float, arm_y: float, t: float) -> void:
	var group: Node3D = _resize_affordances[handle_id]
	_place_segment(group.get_child(0),
			Vector3(cx + arm_x / 2.0, cy, AFFORDANCE_Z), Vector3(absf(arm_x), t, t))
	_place_segment(group.get_child(1),
			Vector3(cx, cy + arm_y / 2.0, AFFORDANCE_Z), Vector3(t, absf(arm_y), t))


## Moves and resizes one affordance segment.
func _place_segment(seg: MeshInstance3D, pos: Vector3, size: Vector3) -> void:
	seg.position = pos
	(seg.mesh as BoxMesh).size = size


## Shows or hides the affordance marks for `handle_id`. Unknown ids are ignored,
## so a release with no active handle is harmless.
func _set_affordance_visible(handle_id: String, is_visible: bool) -> void:
	var group := _resize_affordances.get(handle_id) as Node3D
	if group:
		group.visible = is_visible


## Closes the window: emits on_closed and frees the node.
func close() -> void:
	# Cancel any in-flight resize so a missed RELEASED can't leave stale state
	_resizing = false
	set_process(false)
	on_closed.emit()
	queue_free()
