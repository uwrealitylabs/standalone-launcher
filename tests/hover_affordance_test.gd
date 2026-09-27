extends SceneTree

## Verifies HandPointer's hover events and pointer lifecycle (ENTERED/EXITED per target
## change, hover MOVED from the collision point, drag MOVED from the plane until
## release), that hover never acts on real windows, and that every resize handle stays
## pickable with all windows at maximum width.
##
## Run with:
##   godot --headless --xr-mode off --path . \
##       --script res://tests/hover_affordance_test.gd
##
## "Viewport Texture must be set to use it" errors are expected with no display server.

const Report := preload("res://tests/support/report.gd")

# Mirrors the RayCast3D collision_mask on both controllers in root.tscn.
const POINTER_MASK := 4194304
# A plain layer for the hover-routing bodies, independent of the handle layer.
const HOVER_LAYER := 1
# Clears any width clamp in a single request.
const BIG := 9.0
const EPS := 0.0001

var _report := Report.new()
# Ordered log of XR events the hover targets received, as "<name>:<type>".
var _events: Array[String] = []
# Every XR event the hover targets received, in order, for position checks.
var _raw: Array[XRToolsPointerEvent] = []


## A HandPointer whose pinch the test sets, so the real _process can run with no
## XR controller in the scene.
class FakeHand extends HandPointer:
	var pinch := 0.0

	func _pinch_value() -> float:
		return pinch


func _initialize() -> void:
	await _check_hover_routing()
	await _check_pointer_lifecycle()
	await _check_release_on_collider()
	await _check_press_frame_order()
	await _check_hover_reaches_windows()
	await _check_configured_pickability()
	_report.finish(self)


## Drives a HandPointer's ray across two bodies and empty space, checking that a
## single EXITED then ENTERED pair reaches the colliders on each change and that
## a pinch freezes the target.
func _check_hover_routing() -> void:
	_report.section("hover routing")

	# HandPointer finds its ray as a sibling named "RayCast3D".
	var rig := Node3D.new()
	var ray := RayCast3D.new()
	ray.name = "RayCast3D"
	ray.collision_mask = HOVER_LAYER
	ray.target_position = Vector3(0, 0, -5)
	ray.enabled = true
	rig.add_child(ray)
	var hp := HandPointer.new()
	rig.add_child(hp)
	root.add_child(rig)
	# Only our manual _process_hit_test calls should move hover state.
	hp.set_process(false)

	var a := _hover_body("A", Vector3(-1, 0, -2))
	var b := _hover_body("B", Vector3(1, 0, -2))
	root.add_child(a)
	root.add_child(b)
	await physics_frame
	await physics_frame

	# Aim at A: one enter on A, nothing on B.
	_events.clear()
	_aim(ray, Vector3(-1, 0, 0))
	hp._process_hit_test()
	_report.check("entering A sends ENTERED then one MOVED to A",
			_events == ["A:enter", "A:move"], str(_events))

	# Re-run on the same target: no duplicate events.
	_events.clear()
	hp._process_hit_test()
	_report.check("staying on A sends no further events", _events.is_empty(), str(_events))

	# Switch to B: exit A, then enter B, in that order.
	_events.clear()
	_aim(ray, Vector3(1, 0, 0))
	hp._process_hit_test()
	_report.check("switching to B exits A then enters B",
			_events == ["A:exit", "B:enter", "B:move"], str(_events))

	# Pinch locks the target: aiming away must not retarget or emit.
	_events.clear()
	hp._locked_target = b
	_aim(ray, Vector3(-1, 0, 0))
	hp._process_hit_test()
	_report.check("a locked target is not retargeted", hp._current_target == b)
	_report.check("a locked target emits no hover events", _events.is_empty(), str(_events))
	hp._locked_target = null

	# Leaving every collider: one exit on the current target (B).
	_events.clear()
	_aim(ray, Vector3(0, 5, 0))
	hp._process_hit_test()
	_report.check("leaving all colliders exits B once", _events == ["B:exit"], str(_events))
	_report.check("the pointer holds no target after leaving", hp._current_target == null)

	# Select-up is authoritative: releasing the pinch must deliver RELEASED to the
	# grabbed target even when the ray has already swung off its plane, so a resize
	# can't survive the release. Grab A, then aim the ray parallel to A's plane so
	# the live hit is null, and drop the pinch.
	_aim(ray, Vector3(-1, 0, 0))
	hp._process_hit_test()
	_events.clear()
	hp._process_tap(1.0)
	_report.check("pinch on A grabs it and sends PRESSED", _events == ["A:press"], str(_events))
	# Turn the ray 90 deg about Y so its -Z runs parallel to A's +Z-facing plane;
	# _locked_plane_hit then returns null for the release frame.
	ray.global_rotation = Vector3(0, PI / 2.0, 0)
	ray.force_raycast_update()
	_report.check("the ray now misses A's plane", hp._locked_plane_hit() == null)
	_events.clear()
	hp._process_tap(0.0)
	_report.check("releasing off-plane still sends RELEASED to A",
			_events == ["A:release"], str(_events))
	_report.check("the grab is cleared after release", hp._locked_target == null)
	ray.global_rotation = Vector3.ZERO

	rig.queue_free()
	a.queue_free()
	b.queue_free()
	await process_frame


## Walks one hand through hover, press, an off-collider drag and release on a
## single body, checking event order, which position source each phase uses, and
## that each MOVED carries the previous position as `last_position`.
func _check_pointer_lifecycle() -> void:
	_report.section("pointer lifecycle")

	var rig := Node3D.new()
	var ray := RayCast3D.new()
	ray.name = "RayCast3D"
	ray.collision_mask = HOVER_LAYER
	ray.target_position = Vector3(0, 0, -5)
	ray.enabled = true
	rig.add_child(ray)
	var hp := HandPointer.new()
	rig.add_child(hp)
	root.add_child(rig)
	hp.set_process(false)
	var signals := {"entered": 0, "exited": 0}
	hp.pointer_entered.connect(func(_t: Node) -> void: signals["entered"] += 1)
	hp.pointer_exited.connect(func(_t: Node) -> void: signals["exited"] += 1)

	# The box's front face is at z = -1.95; its facing plane is z = -2.
	var a := _hover_body("A", Vector3(0, 0, -2))
	root.add_child(a)
	await physics_frame
	await physics_frame

	_events.clear()
	_raw.clear()
	_aim(ray, Vector3(0, 0, 0))
	hp._process_hit_test()
	# Holding still produces no motion.
	hp._process_hit_test()
	_aim(ray, Vector3(0.1, 0, 0))
	hp._process_hit_test()
	_report.check("hover enters, then moves only when the point changes",
			_events == ["A:enter", "A:move", "A:move"], str(_events))
	var hover: XRToolsPointerEvent = _raw[2]
	_report.check("hover MOVED is at the collision point",
			hover.position.is_equal_approx(Vector3(0.1, 0, -1.95)), str(hover.position))
	_report.check("hover MOVED carries the previous hover point",
			hover.last_position.is_equal_approx(Vector3(0, 0, -1.95)),
			str(hover.last_position))

	# Press on the collider, then drag the ray off it (A spans x = +/-0.3).
	_events.clear()
	_raw.clear()
	hp._process_tap(1.0)
	_aim(ray, Vector3(0.2, 0, 0))
	hp._process_hit_test()
	hp._process_tap(1.0)
	_aim(ray, Vector3(1.0, 0, 0))
	hp._process_hit_test()
	hp._process_tap(1.0)
	_report.check("a held press sends PRESSED then drag MOVEDs, no hover events",
			_events == ["A:press", "A:move", "A:move"], str(_events))
	var off: XRToolsPointerEvent = _raw[2]
	_report.check("drag MOVED off the collider is on A's plane",
			off.position.is_equal_approx(Vector3(1.0, 0, -2)), str(off.position))
	_report.check("drag MOVED carries the previous drag point",
			off.last_position.is_equal_approx(Vector3(0.2, 0, -2)), str(off.last_position))
	_report.check("the target is kept while pressed off the collider",
			hp._current_target == a)

	# Release off the collider, then the next hover pass exits A.
	_events.clear()
	hp._process_tap(0.0)
	hp._process_hit_test()
	_report.check("release off the collider sends RELEASED, then EXITED",
			_events == ["A:release", "A:exit"], str(_events))
	_report.check("pointer_entered and pointer_exited each fired once",
			signals == {"entered": 1, "exited": 1}, str(signals))

	rig.queue_free()
	a.queue_free()
	await process_frame


## Releases a press while the ray is still on the collider: hover resumes from the
## release point, with no EXITED and no spurious MOVED. An untargeted release
## leaves hover where it was.
func _check_release_on_collider() -> void:
	_report.section("release on the collider")

	var hand := _make_hand(HOVER_LAYER, HandPointer.new())
	var ray: RayCast3D = hand[0]
	var hp: HandPointer = hand[1]
	var a := _hover_body("A", Vector3(0, 0, -2), true)
	root.add_child(a)
	await physics_frame
	await physics_frame

	_aim(ray, Vector3(0, 0, 0))
	hp._process_hit_test()
	hp._process_tap(1.0)
	_aim(ray, Vector3(0.1, 0, 0))
	hp._process_hit_test()
	hp._process_tap(1.0)
	_events.clear()
	_raw.clear()
	hp._process_tap(0.0)
	hp._process_hit_test()
	_report.check("releasing on A sends RELEASED and nothing else while still",
			_events == ["A:release"], str(_events))

	_aim(ray, Vector3(0.15, 0, 0))
	hp._process_hit_test()
	_report.check("moving after release resumes hover MOVED on A",
			_events == ["A:release", "A:move"], str(_events))
	var resumed: XRToolsPointerEvent = _raw.back()
	_report.check("the first hover MOVED starts from the release point",
			resumed.last_position.is_equal_approx(Vector3(0.1, 0, -2)),
			str(resumed.last_position))

	# An untargeted pinch must not rewind hover to the grab above (ended at 0.1).
	_aim(ray, Vector3(2, 0, 0))
	hp._process_hit_test()
	hp._process_tap(1.0)
	_aim(ray, Vector3(0.2, 0, 0))
	hp._process_hit_test()
	_events.clear()
	_raw.clear()
	hp._process_tap(0.0)
	hp._process_hit_test()
	_report.check("an untargeted release sends nothing while the ray is still",
			_events.is_empty(), str(_events))
	_aim(ray, Vector3(0.25, 0, 0))
	hp._process_hit_test()
	_report.check("hover after an untargeted release MOVES on A",
			_events == ["A:move"], str(_events))
	var after_air: XRToolsPointerEvent = _raw.back() if not _raw.is_empty() else null
	_report.check("that MOVED starts from the live hover point, not the old grab",
			after_air != null
			and after_air.last_position.is_equal_approx(Vector3(0.2, 0, -2)),
			str(after_air.last_position) if after_air else "no event")

	ray.get_parent().queue_free()
	a.queue_free()
	await process_frame


## Drives the real _process frame by frame: on the press frame any hover MOVED
## lands before PRESSED, at the same point, then the gesture runs to EXITED.
func _check_press_frame_order() -> void:
	_report.section("_process event order")

	var hp := FakeHand.new()
	var hand := _make_hand(HOVER_LAYER, hp)
	var ray: RayCast3D = hand[0]
	var a := _hover_body("A", Vector3(0, 0, -2), true)
	root.add_child(a)
	await physics_frame
	await physics_frame

	_events.clear()
	_raw.clear()
	_aim(ray, Vector3(0, 0, 0))
	hp._process(0.016)
	# Move and pinch in the same frame.
	_aim(ray, Vector3(0.1, 0, 0))
	hp.pinch = 1.0
	hp._process(0.016)
	_report.check("the press frame sends hover MOVED, then PRESSED",
			_events == ["A:enter", "A:move", "A:move", "A:press"], str(_events))
	_report.check("PRESSED lands where the hover MOVED put the pointer",
			_raw[3].position.is_equal_approx(_raw[2].position),
			"%s vs %s" % [_raw[3].position, _raw[2].position])

	_aim(ray, Vector3(0.2, 0, 0))
	hp._process(0.016)
	hp.pinch = 0.0
	hp._process(0.016)
	_aim(ray, Vector3(0, 5, 0))
	hp._process(0.016)
	_report.check("the rest of the gesture is drag MOVED, RELEASED, EXITED",
			_events.slice(4) == ["A:move", "A:release", "A:exit"], str(_events.slice(4)))

	ray.get_parent().queue_free()
	a.queue_free()
	await process_frame


## Hovers a real HandPointer over an unfocused window's close button and a resize
## handle. Hover must reach them (the button sees the mouse, the handle lights) but
## never act: no press, no close, no focus change, no resize.
func _check_hover_reaches_windows() -> void:
	_report.section("hover over real windows")

	var wm_scene: PackedScene = load("res://project/windowing/window_manager.tscn")
	var wm: WindowManager = wm_scene.instantiate()
	root.add_child(wm)
	await process_frame
	await process_frame

	var focused := wm.get_focused_window()
	var win: SWindow = null
	for w in wm.open_windows:
		if w != focused:
			win = w
	if win == null:
		_report.check("an unfocused window exists to hover", false)
		wm.queue_free()
		await process_frame
		return

	var hand := _make_hand(POINTER_MASK, HandPointer.new())
	var ray: RayCast3D = hand[0]
	var hp: HandPointer = hand[1]
	await physics_frame

	var seen := {"entered": false, "down": false, "pressed": false, "closed": false}
	var close_button: Button = win.header_3d.get_scene_instance().close_button
	close_button.mouse_entered.connect(func() -> void: seen["entered"] = true)
	close_button.button_down.connect(func() -> void: seen["down"] = true)
	close_button.pressed.connect(func() -> void: seen["pressed"] = true)
	win.closed.connect(func() -> void: seen["closed"] = true)

	var header := win.header_3d.get_node("StaticBody3D") as Node3D
	var normal := header.global_transform.basis.z
	var at := _world_of_control(win.header_3d, close_button)
	_aim_along(ray, at, normal)
	hp._process_hit_test()
	_aim_along(ray, at + header.global_transform.basis.x * 0.002, normal)
	hp._process_hit_test()
	await process_frame
	_report.check("the ray is on the unfocused window's header",
			hp._current_target == header, _describe(hp._current_target))
	_report.check("hover reaches the close button as mouse motion", seen["entered"])
	_report.check("hover does not press the close button",
			not seen["down"] and not seen["pressed"], str(seen))
	_report.check("hover does not close the window", not seen["closed"])
	_report.check("hover does not change the focused window",
			wm.get_focused_window() == focused)

	var handle := _handle(win, "R")
	var size_before := win.content_size
	var handle_normal := handle.global_transform.basis.z
	_aim_along(ray, handle.global_position, handle_normal)
	hp._process_hit_test()
	_aim_along(ray, handle.global_position + handle.global_transform.basis.y * 0.01,
			handle_normal)
	hp._process_hit_test()
	await process_frame
	_report.check("the ray is on the right resize handle",
			hp._current_target == handle, _describe(hp._current_target))
	_report.check("hovering the handle lights its affordance",
			win._affordance_hovers["R"].has(hp.get_instance_id()))
	_report.check("hover MOVED on a handle does not start a resize", not win._resizing)
	_report.check("hover MOVED on a handle leaves the size alone",
			win.content_size == size_before, "%s vs %s" % [win.content_size, size_before])
	_report.check("focus is still unchanged", wm.get_focused_window() == focused)

	_aim_along(ray, handle.global_position + handle_normal * 5.0, handle_normal)
	hp._process_hit_test()
	_report.check("leaving the handle clears its affordance",
			not win._affordance_hovers["R"].has(hp.get_instance_id()))

	ray.get_parent().queue_free()
	wm.queue_free()
	await process_frame


## Builds a rig holding a RayCast3D named "RayCast3D" (HandPointer's sibling
## contract) and `hp`, with processing off. Returns [ray, hp].
func _make_hand(mask: int, hp: HandPointer) -> Array:
	var rig := Node3D.new()
	var ray := RayCast3D.new()
	ray.name = "RayCast3D"
	ray.collision_mask = mask
	ray.target_position = Vector3(0, 0, -5)
	ray.enabled = true
	rig.add_child(ray)
	rig.add_child(hp)
	root.add_child(rig)
	hp.set_process(false)
	return [ray, hp]


## Places `ray` in front of `point` along `normal` and aims it back through the
## point, so HandPointer's -Z ray direction crosses the surface head-on.
func _aim_along(ray: RayCast3D, point: Vector3, normal: Vector3) -> void:
	ray.global_transform = Transform3D(Basis.looking_at(-normal), point + normal * 0.5)
	ray.target_position = Vector3(0, 0, -1)
	ray.force_raycast_update()


## World position of `ctrl`'s centre on `surface`, inverting the body's
## viewport-to-screen mapping.
func _world_of_control(surface: XRToolsViewport2DIn3D, ctrl: Control) -> Vector3:
	var shape := surface.get_node("StaticBody3D/CollisionShape3D") as CollisionShape3D
	var vc := ctrl.get_global_rect().get_center()
	var local := Vector3(
			(vc.x / surface.viewport_size.x - 0.5) * surface.screen_size.x,
			(0.5 - vc.y / surface.viewport_size.y) * surface.screen_size.y,
			0.0)
	return shape.global_transform * local


## A StaticBody3D on HOVER_LAYER named `name`, at `pos`, that records the XR
## events it receives into `_events`. With `face_on_plane` the box hangs behind
## `pos`, as window colliders do, so its front face lies on the facing plane.
func _hover_body(name: String, pos: Vector3, face_on_plane := false) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "Hover" + name
	body.collision_layer = HOVER_LAYER
	body.collision_mask = 0
	body.position = pos
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.6, 0.6, 0.1)
	col.shape = box
	if face_on_plane:
		col.position.z = -box.size.z / 2.0
	body.add_child(col)
	body.add_user_signal("pointer_event")
	body.connect("pointer_event",
			func(ev: XRToolsPointerEvent) -> void: _record(name, ev))
	return body


## Records one XR event on the body called `name`.
func _record(name: String, ev: XRToolsPointerEvent) -> void:
	var kind := "enter" if ev.event_type == XRToolsPointerEvent.Type.ENTERED else \
			"exit" if ev.event_type == XRToolsPointerEvent.Type.EXITED else \
			"press" if ev.event_type == XRToolsPointerEvent.Type.PRESSED else \
			"release" if ev.event_type == XRToolsPointerEvent.Type.RELEASED else \
			"move" if ev.event_type == XRToolsPointerEvent.Type.MOVED else "other"
	_events.append("%s:%s" % [name, kind])
	_raw.append(ev)


## Aims `ray` straight down -Z from `origin`, so it hits whatever sits on that
## axis.
func _aim(ray: RayCast3D, origin: Vector3) -> void:
	ray.global_position = origin
	ray.force_raycast_update()


## Grows every window to its legal maximum width, then casts a ray at each of its
## resize handles: the ray must land on that window's own handle, proving the
## bands do not become ambiguous between neighbours at the widest legal layout.
func _check_configured_pickability() -> void:
	_report.section("handles pickable at legal max widths")

	var wm_scene: PackedScene = load("res://project/windowing/window_manager.tscn")
	var wm: WindowManager = wm_scene.instantiate()
	root.add_child(wm)
	await process_frame
	# Fill the last slot so all three arc positions are occupied.
	wm.create_window()
	await process_frame

	# Grow each window to the widest it is allowed beside the others. The managed
	# clamp keeps the permutation-safe invariant, so the end state is legal.
	for w in wm.open_windows:
		w.resize(Vector2(BIG, w.content_size.y))
	await process_frame

	var ray := RayCast3D.new()
	ray.collision_mask = POINTER_MASK
	root.add_child(ray)
	await physics_frame

	var all_ok := true
	for w in wm.open_windows:
		for handle_id in ["L", "R", "B", "BL", "BR"]:
			var body := _handle(w, handle_id)
			var hit := _cast_at_handle(ray, body)
			if hit != body:
				all_ok = false
				_report.check("handle %s of a window is the first pick (got %s)"
						% [handle_id, _describe(hit)], false)
	_report.check("every handle is pickable and unambiguous at max width", all_ok)

	ray.queue_free()
	wm.queue_free()
	await process_frame


## Casts along `body`'s own outward normal, from just in front of it, and returns
## the first collider the pointer mask sees, or null for a miss.
func _cast_at_handle(ray: RayCast3D, body: StaticBody3D) -> Object:
	# The handle inherits the window's facing; basis.z points toward the viewer.
	var normal: Vector3 = body.global_transform.basis.z
	var origin := body.global_position + normal * 0.5
	ray.global_position = origin
	ray.global_rotation = Vector3.ZERO
	# target_position is in the (now axis-aligned) ray's local space; reach past
	# the handle so its front face is the nearest hit.
	ray.target_position = (body.global_position - normal * 0.2) - origin
	ray.force_raycast_update()
	return ray.get_collider() if ray.is_colliding() else null


## The handle body `win` tags with `handle_id`, or null when absent.
func _handle(win: SWindow, handle_id: String) -> StaticBody3D:
	var handles := win.get_node_or_null("ResizeHandles")
	if handles == null:
		return null
	for child in handles.get_children():
		if child.get_meta("handle_id", "") == handle_id:
			return child as StaticBody3D
	return null


func _describe(node: Object) -> String:
	if node == null:
		return "nothing"
	return str((node as Node).get_path())
