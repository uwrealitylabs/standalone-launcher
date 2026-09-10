class_name SWindow extends Node3D

# WindowManager owns placement, writing this window's transform from its assigned
# slot; the window never writes its own position. A resize keeps the centre fixed.

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

# True while this window is suspended behind a solo presentation (a sibling of the
# soloed window): surfaces hidden, all collision and key routing off.
var is_suspended := false
# True while this window (the soloed one) is interaction-locked for a tween:
# collision and key routing off, mesh and redraw still live.
var _interaction_locked := false
# True while the manager is running a solo enter/exit tween on this window. Kept
# separate from _resizing so both can gate _process through one owner.
var _transitioning := false

# Resize window variables
var _resizing           := false
var _resize_handle      := ""
# Grab point in the window's OWN frame; mid-gesture hits convert back to it, so
# displacement is measured relative to the window. Keeps the resize fixed-centre,
# rotation-safe, and immune to the window moving mid-gesture (e.g. locomotion
# sliding the whole arc while a resize is live).
var _resize_start_local := Vector3.ZERO
var _resize_start_size  := Vector2.ZERO
# Permutation-safe width cap, frozen at gesture start so mid-gesture frames need
# no rescan; read through clamp_content_size while _resizing.
var _resize_max_width   := MAX_CONTENT_SIZE.x

# Grab bands straddling the content edges, keyed by handle id
var _resize_handles := {}
# Unshaded white marks hinting each handle, keyed by handle id. Pure visuals (no
# collision); shown while any ray hovers the handle.
var _resize_affordances := {}
# Which pointers hover each handle: handle id -> set of pointer instance ids (0 for
# a null/synthetic pointer). Counted per pointer so one hand's EXITED can't hide a
# mark the other hand is still on.
var _affordance_hovers := {}
# Nominal length of a mark along its edge, capped to a fraction of that edge so
# the two bottom corners never overlap and a mark never spans its whole side.
const AFFORDANCE_LENGTH := 0.12
const AFFORDANCE_THICKNESS := 0.006
# In front of the handle bodies (viewer on +z) so the marks never Z-fight the
# screen or the collision boxes.
const AFFORDANCE_Z := HANDLE_Z + HANDLE_DEPTH / 2.0 + 0.001
# Thickness tracks the window (a small one isn't mostly handle) but caps out. The
# ratio stays under half so _layout_resize_handles spans stay positive at MIN size.
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

# Size of the actual content, not the header. Persistent across a solo
# presentation, which uses `current_solo_size` instead. The literal is a
# placeholder.
var content_size := Vector2(1.5, 0.75)
# Animated/live solo presentation size. Meaningful only while this window is
# `manager.soloed_window` (manager state ENTERING/SOLO/EXITING); reset to
# Vector2.ZERO after exit completes.
var current_solo_size := Vector2.ZERO
# The size the geometry currently reflects — the argument of the last _apply_size,
# independent of which persistent field (content_size / current_solo_size) is
# authoritative. The resolution subsystem and the geometry helpers read this.
var _active_size := Vector2.ZERO
const HEADER_HEIGHT  : float = 0.08     # fixed header height in world units
const MIN_CONTENT_SIZE := Vector2(0.4, 0.2)
const MAX_CONTENT_SIZE := Vector2(3.0, 2.5)
# Render density of each surface. Held constant across resizes so a bigger
# window buys more room rather than bigger content.
var PIXELS_PER_UNIT := 150.0
var HEADER_PIXELS_PER_UNIT := 150.0

# Live-resize resolution throttle. Reallocating a render target relays out its 2D
# scene, so committing every drag frame risks a hitch and a visible re-wrap.
# MAX_STRETCH bounds how far the targets may lag the quads; the interval is only a
# ceiling on commit rate.
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
	_active_size = content_size
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


## Routes or unroutes physical keyboard/gamepad input to this window's surfaces.
## Interaction concern only: it does not tell the content that focus changed, so
## a transition lock can cut input without reporting a focus loss that never
## happened.
func _set_key_routing(enabled: bool) -> void:
	content_3d.input_keyboard = enabled
	content_3d.input_gamepad = enabled
	# Gate the header's keys too, or every title bar keeps taking physical keys
	# regardless of focus. Its gamepad flag is left as authored (off).
	header_3d.input_keyboard = enabled


## Tells the content scene, if it defines on_window_focus_changed(bool), that
## focus moved. Notification concern only: it routes no input.
func _notify_content_focus(enabled: bool) -> void:
	# content_3d reports null until the scene is set on first focus; nothing to
	# notify before then.
	var scene := content_3d.get_scene_instance()
	if scene and scene.has_method("on_window_focus_changed"):
		scene.on_window_focus_changed(enabled)


## Sets whether input events will be directed to this window, and tells the
## content scene that focus moved. Used by the manager's focus(); preserves the
## combined behaviour of the two concerns above.
func set_input_enabled(enabled: bool) -> void:
	_set_key_routing(enabled)
	_notify_content_focus(enabled)

## Notifies the content scene, if it defines on_window_suspended(bool), that it
## was suspended or reactivated behind a solo presentation.
func _notify_content_suspended(suspended: bool) -> void:
	var scene := content_3d.get_scene_instance()
	if scene and scene.has_method("on_window_suspended"):
		scene.on_window_suspended(suspended)


## Sets the `disabled` flag on every resize handle's collider — true disables
## picking, false restores it. Named for the flag it writes so the call site
## reads plainly (`_set_handles_disabled(true)` disables). Handles are separate
## bodies under ResizeHandles, so the addon's visibility cascade never reaches
## them; suspend/lock must toggle them explicitly.
func _set_handles_disabled(disabled: bool) -> void:
	for body: StaticBody3D in _resize_handles.values():
		(body.get_child(0) as CollisionShape3D).disabled = disabled


## Clears every handle's hover state and hides its affordance mark. A handle whose
## collider is being disabled while a ray hovers it never emits EXITED, so its
## separate visible mark would otherwise hang in the air. Call whenever handle
## collision is taken away.
func _clear_hover_affordances() -> void:
	for hovers: Dictionary in _affordance_hovers.values():
		hovers.clear()
	for group: Node3D in _resize_affordances.values():
		group.visible = false


## Suspends or reactivates this window as a sibling of a solo presentation.
## Idempotent. Suspending hides both surfaces (which stops redraw and, through the
## addon's visibility cascade, disables their screen colliders), disables every
## resize handle's collider explicitly, clears hover marks, and cuts key routing.
## Reactivating reverses visibility and handle collision. Focus routing is owned
## by focus(), not here.
func set_suspended(suspended: bool) -> void:
	if is_suspended == suspended:
		return
	is_suspended = suspended
	if suspended:
		content_3d.visible = false
		header_3d.visible = false
		_set_handles_disabled(true)
		_clear_hover_affordances()
		_set_key_routing(false)
	else:
		content_3d.visible = true
		header_3d.visible = true
		_set_handles_disabled(false)
	_notify_content_suspended(suspended)


## Locks or unlocks interaction on the soloed window for the length of a solo
## tween: toggles collision and key routing only, leaving the mesh and redraw
## live. Locking disables both screen colliders (through the surfaces' `enabled`,
## since they stay visible) and every handle collider, and clears hover marks.
## Unlock derives key-routing eligibility from focus (never a blind enable) and
## never fires the focus hook. Idempotent.
func set_interaction_locked(locked: bool) -> void:
	if _interaction_locked == locked:
		return
	_interaction_locked = locked
	content_3d.enabled = not locked
	header_3d.enabled = not locked
	_set_handles_disabled(locked)  # disabled == locked
	if locked:
		_clear_hover_affordances()
		_set_key_routing(false)
	else:
		_set_key_routing(manager != null and manager.focused_window == self)


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
	# Driven on a clock, not from update_resize, so a resize (or a transition tween
	# sampling live sizes) that stops moving without releasing still catches its
	# resolution up. _update_processing owns whether this runs at all.
	_tick_resolution(delta)


## Single owner of set_process: the resolution clock must run while either a
## resize gesture or a solo transition is live. Every field write that changes
## either must call this instead of set_process directly.
func _update_processing() -> void:
	set_process(_resizing or _transitioning)


## Sets whether the manager is running a solo tween on this window, keeping the
## resolution clock live for the duration. See [method _update_processing].
func set_transitioning(on: bool) -> void:
	_transitioning = on
	_update_processing()

## The window's resize plane at its CURRENT pose: the visible surface through the
## window origin, facing along its normal. Rebuilt each frame so a window moved
## mid-gesture (e.g. by locomotion) is measured against where it is now, not where
## it was grabbed.
func _live_resize_plane() -> Plane:
	var xf := global_transform.orthonormalized()
	return Plane(xf.basis.z, xf.origin)


## Starts a resize on `handle` ("L", "R", "B", "BL" or "BR") from the grab
## described by `event`. No-op when the pointer ray misses the window's plane.
func start_resize(handle: String, event: XRToolsPointerEvent) -> void:
	# Focus, then anchor the grab in the window's own frame (to_local) so later
	# frames can re-measure against the live window.
	focus()
	# Gate on the manager's interaction state after focus (a docked focus request
	# always succeeds, so the pressed window qualifies): a suspended sibling or a
	# window mid-transition must not resize itself.
	if manager and not manager.can_interact(self):
		return
	var hit = _resolve_pointer_hit(event, _live_resize_plane())
	if hit == null:
		return
	# Take exclusive resize ownership before storing any gesture state; a refusal
	# (another window is already resizing) leaves this window untouched.
	if manager and not manager.acquire_resize(self):
		return
	_resizing           = true
	_resize_handle      = handle
	_resize_start_local = to_local(hit)
	_resize_start_size  = _presentation_size()
	# Freeze the width cap: exclusive ownership means no other window's width
	# changes, so it stays valid for the whole gesture.
	_resize_max_width   = manager.max_content_width_for(self) if manager else MAX_CONTENT_SIZE.x
	_update_processing()


## Resizes the window to follow the pointer at `hit_world`, keeping the content
## centre fixed and growing symmetrically. No-op when no resize is in flight.
func update_resize(hit_world: Vector3) -> void:
	if not _resizing:
		return
	# Displacement from the grab, both points window-local so any rigid motion since
	# the grab cancels out. Fixed-centre rule: the grabbed edge follows the pointer
	# and the opposite edge mirrors it, so the dimension changes by twice the
	# displacement. Route through the internal policy directly (not the public
	# resize(), which cancels gestures) so the managed clamp can't be bypassed.
	var d := to_local(hit_world) - _resize_start_local
	var dx := d.x
	var dy := d.y
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

	_apply_resize_request(_resize_start_size + Vector2(dw, dh), true)


## Cancels any in-flight resize gesture: ends it, releases resize ownership,
## resets the frozen width cap, settles the geometry at the current presentation
## size, and clears gesture state so no later pointer frame can resume the old
## drag. Does not revert the size already applied. No-op when not resizing.
func cancel_resize() -> void:
	if not _resizing:
		return
	_resizing           = false
	_resize_handle      = ""
	_resize_start_local = Vector3.ZERO
	_resize_start_size  = Vector2.ZERO
	_resize_max_width   = MAX_CONTENT_SIZE.x
	if manager:
		manager.release_resize(self)
	_update_processing()
	_apply_size(_presentation_size())


## Ends the resize and settles the render resolutions at the final size.
func stop_resize() -> void:
	_resizing      = false
	# The mark is driven purely by hover, so it is left as-is here: still shown if
	# the ray is on the handle, and cleared later by the handle's own EXITED.
	_resize_handle = ""
	if manager:
		manager.release_resize(self)
	_update_processing()
	# Gesture over: settle exactly, whatever the throttle last committed
	_apply_size(_presentation_size())


## Public programmatic resize entry to `desired`. Existing callers (tests, window
## creation) use this. When managed it delegates to WindowManager.resize_window so
## it inherits the state gate and the unconditional gesture cancel; unmanaged (a
## headless fixture) it falls back to the numeric clamp. Not on the gesture path —
## update_resize calls the internal policy directly, so this wrapper's cancel is
## safe. `live` applies only to the unmanaged fallback; the managed path always
## settles (a programmatic resize is not a drag frame).
func resize(desired: Vector2, live: bool = false) -> void:
	if manager:
		manager.resize_window(self, desired)
	else:
		content_size = desired.clamp(MIN_CONTENT_SIZE, MAX_CONTENT_SIZE)
		_apply_size(content_size, live)


## The size this window currently presents at: its live solo size while it is the
## manager's soloed window, otherwise its persistent content_size. Every "current
## size" read goes through here so the solo and content sizes stay separate.
func _presentation_size() -> Vector2:
	if manager and manager.soloed_window == self:
		return current_solo_size
	return content_size


## Internal resize policy: clamps `desired` for the current presentation mode,
## writes the owning size field, and applies the geometry. Gesture frames and the
## programmatic resize path call this; it is not the public entry. `live` omits
## the render resolutions, as in [method _apply_size].
func _apply_resize_request(desired: Vector2, live: bool = false) -> void:
	if manager and manager.soloed_window == self:
		# Solo path: clamp to solo safety limits and write the live solo size only.
		current_solo_size = manager.clamp_solo_size(self, desired)
		_apply_size(current_solo_size, live)
	elif manager:
		content_size = manager.clamp_content_size(self, desired)
		_apply_size(content_size, live)
	else:
		# Standalone window (e.g. a headless test fixture): numeric clamp only.
		content_size = desired.clamp(MIN_CONTENT_SIZE, MAX_CONTENT_SIZE)
		_apply_size(content_size, live)


## Mode-independent geometry writer: drives the quad, collision, header
## placement, resize handles and affordances from `size`, and records it as
## [member _active_size] for the resolution subsystem. It does NOT decide or write
## which persistent size field is authoritative — the caller owns that write. It
## does not re-clamp; callers pass an already-clamped size. `live` omits the
## render resolutions; the caller must call again without it to settle them.
func _apply_size(size: Vector2, live: bool = false) -> void:
	_active_size = size
	var header_size := Vector2(size.x, HEADER_HEIGHT)

	# Assigning screen_size drives the quad, the static body's translator and
	# the collision shape as one, so they cannot disagree mid-gesture.
	content_3d.screen_size = size
	header_3d.screen_size = header_size
	# Header sits on top of the content; both are centred on the window
	header_3d.position.y = (size.y + HEADER_HEIGHT) / 2.0
	_layout_resize_handles()
	_layout_resize_affordances()

	if live:
		_res_pending = true
		return

	_commit_resolution()


## Reallocates both render targets so each surface renders at its authored
## pixel density for the current content size.
func _commit_resolution() -> void:
	var header_size := Vector2(_active_size.x, HEADER_HEIGHT)
	content_3d.viewport_size = _viewport_resolution(_active_size, PIXELS_PER_UNIT)
	header_3d.viewport_size = _viewport_resolution(header_size, HEADER_PIXELS_PER_UNIT)
	# Resizing a render target clears it; the addon's own refill runs on an
	# unrelated clock, so re-arm the redraw here to avoid a visible blank flash.
	_request_redraw(content_3d)
	_request_redraw(header_3d)
	_res_basis = _active_size
	_res_pending = false
	_since_commit = 0.0


## Asks `surface` to redraw its viewport once on the coming frame.
func _request_redraw(surface: XRToolsViewport2DIn3D) -> void:
	var viewport := surface.get_node("Viewport") as SubViewport
	# Assign unconditionally: the renderer resets its own copy after drawing, so
	# skipping the write when it already reads UPDATE_ONCE would skip the redraw.
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
	return absf(_active_size.x / _res_basis.x - 1.0) > MAX_STRETCH \
			or absf(_active_size.y / _res_basis.y - 1.0) > MAX_STRETCH


## Render resolution for a screen of `size` world units at `ppu` pixels per
## unit, rounded, never smaller than one pixel on either axis.
func _viewport_resolution(size: Vector2, ppu: float) -> Vector2:
	# A zero-sized viewport is invalid, so the floor is a hard requirement
	return Vector2(maxf(1.0, roundf(size.x * ppu)), maxf(1.0, roundf(size.y * ppu)))


## Invoked when a resize handle's pointer event signal is received
func _on_handle_pointer_event(handle_id: String, event: XRToolsPointerEvent) -> void:
	match event.event_type:
		XRToolsPointerEvent.Type.ENTERED:
			_set_handle_hovered(handle_id, event.pointer, true)
		XRToolsPointerEvent.Type.EXITED:
			_set_handle_hovered(handle_id, event.pointer, false)
		XRToolsPointerEvent.Type.PRESSED:
			start_resize(handle_id, event)
		XRToolsPointerEvent.Type.MOVED:
			var hit = _resolve_pointer_hit(event, _live_resize_plane())
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
	var hw := _active_size.x / 2.0
	var hh := _active_size.y / 2.0
	var tx := minf(HANDLE_MAX_THICKNESS, _active_size.x * HANDLE_THICKNESS_RATIO)
	var ty := minf(HANDLE_MAX_THICKNESS, _active_size.y * HANDLE_THICKNESS_RATIO)

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
		_affordance_hovers[handle_id] = {}

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
	var hw := _active_size.x / 2.0
	var hh := _active_size.y / 2.0
	var t := AFFORDANCE_THICKNESS
	# Cap each mark to a fraction of its edge so the two bottom corners never
	# overlap and no mark spans a whole side.
	var len_x := minf(AFFORDANCE_LENGTH, _active_size.x * 0.4)
	var len_y := minf(AFFORDANCE_LENGTH, _active_size.y * 0.4)

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


## Records whether `pointer` hovers `handle_id`, then shows the mark while any
## pointer still hovers it. Per-pointer counting keeps one hand's exit from hiding
## a mark the other hand is on. Unknown handle ids are ignored.
func _set_handle_hovered(handle_id: String, pointer: Node3D, hovered: bool) -> void:
	# Null-check while still untyped: assigning a missing key's null straight into
	# a typed Dictionary would raise before the guard could run.
	var raw = _affordance_hovers.get(handle_id)
	if raw == null:
		return
	var hovers: Dictionary = raw
	# Key by instance id, not the node itself, so a freed pointer never lingers as
	# a live reference. 0 stands in for a null/synthetic pointer.
	var key := pointer.get_instance_id() if is_instance_valid(pointer) else 0
	if hovered:
		hovers[key] = true
	else:
		hovers.erase(key)
	var group := _resize_affordances.get(handle_id) as Node3D
	if group:
		group.visible = not hovers.is_empty()


## Closes the window: emits on_closed and frees the node.
func close() -> void:
	# Cancel any in-flight resize so a missed RELEASED can't leave stale state
	_resizing = false
	_update_processing()
	on_closed.emit()
	queue_free()
