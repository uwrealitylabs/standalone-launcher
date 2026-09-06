extends SceneTree

## Verifies HandPointer's hover routing and that the arc's resize handles stay
## individually pickable when every window is at its legal maximum width.
##
## HandPointer delivers XRToolsPointerEvent ENTERED/EXITED to the collider under
## the ray, one pair per target change and in that order (exit the old, enter the
## new), alongside its public hover signals. It never retargets mid-pinch.
##
## Run with:
##   godot --headless --xr-mode off --path . \
##       --script res://tests/hover_affordance_test.gd
##
## --xr-mode off is required: without it a modal OpenXR alert hangs the run.
##
## The "Viewport Texture must be set to use it" errors are expected with no
## display server, not failures.

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


func _initialize() -> void:
	await _check_hover_routing()
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
	_report.check("entering A sends exactly one ENTERED to A", _events == ["A:enter"],
			str(_events))

	# Re-run on the same target: no duplicate events.
	_events.clear()
	hp._process_hit_test()
	_report.check("staying on A sends no further events", _events.is_empty(), str(_events))

	# Switch to B: exit A, then enter B, in that order.
	_events.clear()
	_aim(ray, Vector3(1, 0, 0))
	hp._process_hit_test()
	_report.check("switching to B exits A then enters B", _events == ["A:exit", "B:enter"],
			str(_events))

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


## A StaticBody3D on HOVER_LAYER named `name`, at `pos`, that records the XR
## events it receives into `_events`.
func _hover_body(name: String, pos: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "Hover" + name
	body.collision_layer = HOVER_LAYER
	body.collision_mask = 0
	body.position = pos
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.6, 0.6, 0.1)
	col.shape = box
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
			"release" if ev.event_type == XRToolsPointerEvent.Type.RELEASED else "other"
	_events.append("%s:%s" % [name, kind])


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
