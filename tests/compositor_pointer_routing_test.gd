extends SceneTree

## Verifies Milestone 3's wiring: a HandPointer aimed at compositor_screen.tscn
## reaches the Wayland seat as surface-UV pointer calls.
##
## WaylandPointerRouter's arbitration has its own suite
## (wayland_pointer_router_test.gd); this one drives a real ray and HandPointer
## against the scene's collider and asserts the parts in between:
##
##   - the collider sits on the pointer layer and is pointable only while shown;
##   - it follows the quad when a surface maps at a new aspect;
##   - world hits convert to UV under the placement root.tscn uses, including
##     past the edge during a pressed drag;
##   - unmapping forgets the hands.
##
## As in compositor_keyboard_routing_test.gd, autostart is off and a fake
## compositor records the calls, so the suite runs the same on every host.
##
## Run with:
##   godot --headless --xr-mode off --path . \
##       --script res://tests/compositor_pointer_routing_test.gd

const Report := preload("res://tests/support/report.gd")

const SCREEN_SCENE := "res://project/compositor/compositor_screen.tscn"
const POINTER_LAYER := 4194304
const SURF := Vector2i(1280, 720)
const EPS := 0.001


## Stands in for WaylandCompositor, recording pointer calls as [name, uv] pairs.
## Extends Node because compositor_poc.gd holds its compositor in a Node field.
class FakeCompositor:
	extends Node
	var calls: Array = []

	func pointer_enter(uv: Vector2) -> void:
		calls.append(["enter", uv])

	func pointer_motion(uv: Vector2) -> void:
		calls.append(["motion", uv])

	func pointer_leave() -> void:
		calls.append(["leave", null])

	func send_button(_button: int, pressed: bool) -> void:
		calls.append(["down" if pressed else "up", null])

	# Keyboard focus follows map and unmap; teardown asks for stats and stop.
	func set_keyboard_focus(_focused: bool) -> void:
		pass

	func set_toplevel_activated(_activated: bool) -> void:
		pass

	func get_stats() -> Dictionary:
		return {}

	func stop() -> void:
		pass


var _report := Report.new()


func _initialize() -> void:
	var scene: PackedScene = load(SCREEN_SCENE)
	if scene == null:
		_report.check("compositor_screen.tscn loads", false)
		_report.finish(self)
		return
	var screen := scene.instantiate() as MeshInstance3D
	screen.autostart = false
	# Where root.tscn puts it, so the UV conversion sees a real transform.
	screen.transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 2),
			Vector3(0, 2.5, -2))
	root.add_child(screen)
	await process_frame

	var fake := FakeCompositor.new()
	screen.add_child(fake)
	screen._compositor = fake

	var ray := RayCast3D.new()
	ray.collision_mask = POINTER_LAYER
	ray.enabled = true
	var hp := HandPointer.new()
	var rig := Node3D.new()
	ray.name = "RayCast3D"
	rig.add_child(ray)
	rig.add_child(hp)
	root.add_child(rig)
	# Only the suite's manual calls should move the pointer.
	hp.set_process(false)

	await _check_collider(screen)
	_check_uv_path(screen, fake, ray, hp)
	await _check_hide_and_unmap(screen, fake, ray, hp)
	_report.finish(self)


func _shape(screen: MeshInstance3D) -> CollisionShape3D:
	return screen.get_node("StaticBody3D/CollisionShape3D") as CollisionShape3D


func _check_collider(screen: MeshInstance3D) -> void:
	_report.section("the collider")
	var body := screen.get_node_or_null("StaticBody3D") as StaticBody3D
	_report.check("a StaticBody3D child exists", body != null)
	if body == null:
		return
	_report.check("it is on the pointer layer and masks nothing",
			body.collision_layer == POINTER_LAYER and body.collision_mask == 0)
	_report.check("it has no pointer_event signal, so HandPointer reaches the screen",
			not body.has_signal("pointer_event") and screen.has_signal("pointer_event"))
	_report.check("the shape starts disabled while the quad is hidden",
			_shape(screen).disabled)

	screen._on_surface_mapped(SURF)
	var quad := screen.mesh as QuadMesh
	var box := _shape(screen).shape as BoxShape3D
	_report.check("mapping 16:9 widens the quad", is_equal_approx(quad.size.x, 0.6 * 16 / 9),
			str(quad.size))
	_report.check("the box follows the quad",
			is_equal_approx(box.size.x, quad.size.x) and is_equal_approx(box.size.y, quad.size.y),
			str(box.size))
	_report.check("the box's front face lies on the quad's plane",
			is_equal_approx(_shape(screen).position.z + box.size.z / 2, 0.0))

	# Stands in for the first frame binding, which only a real compositor gives.
	screen.visible = true
	await physics_frame
	await physics_frame
	_report.check("the shape is enabled once the quad shows", not _shape(screen).disabled)


func _check_uv_path(screen: MeshInstance3D, fake: FakeCompositor, ray: RayCast3D,
		hp: HandPointer) -> void:
	_report.section("hand to surface UV")
	_aim(screen, ray, Vector2(0.5, 0.5))
	hp._process_hit_test()
	_report.check("aiming at the centre enters at (0.5, 0.5)",
			_calls_match(fake.calls, [["enter", Vector2(0.5, 0.5)]]), str(fake.calls))

	fake.calls.clear()
	_aim(screen, ray, Vector2(0.25, 0.8))
	hp._process_hit_test()
	_report.check("hover converts with (0, 0) at the top-left",
			_calls_match(fake.calls, [["motion", Vector2(0.25, 0.8)]]), str(fake.calls))

	fake.calls.clear()
	hp._process_tap(1.0)
	_aim(screen, ray, Vector2(1.3, -0.2))
	hp._process_hit_test()
	hp._process_tap(1.0)
	_report.check("a pressed drag past the corner keeps unclamped UV, with no leave",
			_calls_match(fake.calls, [["down", null], ["motion", Vector2(1.3, -0.2)]]),
			str(fake.calls))

	fake.calls.clear()
	hp._process_tap(0.0)
	hp._process_hit_test()
	_report.check("release sends button up, then the ray being off leaves",
			_calls_match(fake.calls, [["up", null], ["leave", null]]), str(fake.calls))


func _check_hide_and_unmap(screen: MeshInstance3D, fake: FakeCompositor, ray: RayCast3D,
		hp: HandPointer) -> void:
	_report.section("hiding and unmapping")
	_aim(screen, ray, Vector2(0.5, 0.5))
	hp._process_hit_test()
	hp._process_tap(1.0)
	_report.check("the hand owns the pointer, pressed",
			screen._pointer_router.get_pointer_owner() == hp)

	fake.calls.clear()
	screen._on_surface_unmapped()
	await physics_frame
	await physics_frame
	_report.check("unmap forgets the hand without sending anything",
			screen._pointer_router.get_pointer_owner() == null and fake.calls.is_empty(),
			str(fake.calls))
	_report.check("the hidden quad's shape is disabled again", _shape(screen).disabled)

	# The hand's gesture outlives the surface; its tail must not reach the seat.
	hp._process_tap(0.0)
	ray.force_raycast_update()
	hp._process_hit_test()
	_report.check("the gesture's release and exit send nothing", fake.calls.is_empty(),
			str(fake.calls))


## Aims `ray` head-on at the point with surface UV `uv` on `screen`.
func _aim(screen: MeshInstance3D, ray: RayCast3D, uv: Vector2) -> void:
	var quad := screen.mesh as QuadMesh
	var point := screen.global_transform * Vector3(
			(uv.x - 0.5) * quad.size.x, (0.5 - uv.y) * quad.size.y, 0.0)
	var normal := screen.global_basis.z.normalized()
	ray.global_transform = Transform3D(Basis.looking_at(-normal), point + normal * 0.5)
	ray.target_position = Vector3(0, 0, -1)
	ray.force_raycast_update()


## Whether `calls` matches `want` by name, with UVs equal to within EPS.
func _calls_match(calls: Array, want: Array) -> bool:
	if calls.size() != want.size():
		return false
	for i in calls.size():
		if calls[i][0] != want[i][0]:
			return false
		if want[i][1] != null and (calls[i][1] as Vector2).distance_to(want[i][1]) > EPS:
			return false
	return true
