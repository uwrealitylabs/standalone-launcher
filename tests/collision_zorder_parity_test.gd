extends SceneTree

## Verifies that on each docked window's content collider, the ray's hit on the facing
## plane `_locked_plane_hit` uses equals the raycast collision point. Presses need the
## plane off the collider; this agreement makes the hover-to-press handoff seamless and
## is not a reason to merge the two sources.
##
## Run with:
##   godot --headless --xr-mode off --path . \
##       --script res://tests/collision_zorder_parity_test.gd
##
## "Viewport Texture must be set to use it" errors are expected with no display server.

const Report := preload("res://tests/support/report.gd")

# 0.1 mm: below any collider/transform float noise, far above the exact-zero gap
# the coplanar geometry actually produces.
const EPS := 0.0001

var _report := Report.new()


## The SWindow that owns `body`, walking up from a hit collider.
func _window_of(body: Node) -> SWindow:
	var n := body
	while n != null:
		if n is SWindow:
			return n
		n = n.get_parent()
	return null


## The facing plane HandPointer would derive from a locked `body` collider,
## matching hand_pointer._locked_plane_hit.
func _body_plane(body: Node3D) -> Plane:
	var t := body.global_transform
	return Plane(t.basis.z, t.origin)


func _phys_pick(space: PhysicsDirectSpaceState3D, ro: Vector3, rd: Vector3) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(ro, ro + rd * 20.0)
	# Window colliders sit on custom layers; probe every layer.
	q.collision_mask = 0xFFFFFFFF
	return space.intersect_ray(q)


func _initialize() -> void:
	var wm_scene: PackedScene = load("res://project/windowing/window_manager.tscn")
	var wm: WindowManager = wm_scene.instantiate()
	root.add_child(wm)
	await process_frame

	# Clear the hardcoded startup windows so only the fixture stack is in play.
	for w in wm.open_windows.duplicate():
		w.close()
	await process_frame

	# Fill all three slots. Bare colliders suffice: the claim is about the content
	# box geometry, not what renders in it.
	wm.create_window()
	wm.create_window()
	wm.create_window()
	for i in 6:
		await physics_frame

	# Handles jut in front of the content plane (HANDLE_Z) and the header has its
	# own plane, so silence both: the raycast should see only the content box.
	for w in wm.open_windows:
		var header := w.get_node("Header/StaticBody3D") as CollisionObject3D
		header.collision_layer = 0
		var handles := w.get_node_or_null("ResizeHandles")
		if handles:
			for h in handles.get_children():
				(h as CollisionObject3D).collision_layer = 0
	await physics_frame

	var wins := wm.open_windows.duplicate()
	var space := root.world_3d.direct_space_state
	# Every slot faces the arc's reference point, so a sweep from here crosses each
	# window head-on.
	var eye := wm.reference_point

	_report.section("setup")
	_report.check("three fixture windows", wins.size() == 3, str(wins.size()))

	# The windows span about ±63° in azimuth, so a slightly wider sweep crosses all
	# three and the gaps between them.
	var hits := 0
	var point_ok := 0
	var worst_point := 0.0
	var wins_seen := {}

	var deg := -70.0
	while deg <= 70.0:
		var a := deg_to_rad(deg)
		var rd := Vector3(sin(a), 0.0, -cos(a))

		var r := _phys_pick(space, eye, rd)
		if not r.is_empty():
			var win := _window_of(r["collider"])
			if win != null:
				hits += 1
				wins_seen[win] = true

				# Point parity: plane on the physics-hit collider vs its point.
				var body := r["collider"] as Node3D
				var ph = _body_plane(body).intersects_ray(eye, rd)
				if ph != null:
					var gap: float = (ph - r["position"]).length()
					worst_point = maxf(worst_point, gap)
					if gap < EPS:
						point_ok += 1
		deg += 1.0

	_report.section("coverage")
	# A sweep that only ever grazed one window would pass the parity check
	# trivially, so assert the arc actually exposed every fixture window.
	_report.check("physics hit windows", hits > 0, str(hits))
	_report.check("sweep exposed all three windows", wins_seen.size() == 3,
			str(wins_seen.size()))

	_report.section("point parity")
	_report.check("plane hit equals collision point on the picked window",
			point_ok == hits, "%d/%d" % [point_ok, hits])
	_report.check("worst point gap under eps", worst_point < EPS,
			"%.6f" % worst_point)

	_report.finish(self)
