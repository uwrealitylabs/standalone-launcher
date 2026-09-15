extends SceneTree

## Verifies that the two ways the pointer can resolve a hit agree on z-order.
##
## HandPointer selects a target with a physics raycast (a finite collider) but
## then computes the gesture position by intersecting the ray with that target's
## facing plane (`_locked_plane_hit`). The plane is only sound as a stand-in for
## the collision point because each window's collider is a thin box hung BEHIND
## the quad, so its front face lands on `Plane(body.basis.z, body.origin)`. This
## suite pins that contract: over a ray sweep across overlapping windows,
##
##   * the ray/plane hit on the physics-picked window equals the collision point
##     (same landing point, so same depth), and
##   * the nearest in-bounds plane picks the same window the physics raycast does
##     (same z-order selection).
##
## If the collider offset drifts so the front face no longer sits on that plane,
## the point check fails; if plane and collider selection can diverge in the
## region gestures use, the selection check fails.
##
## Run with:
##   godot --headless --xr-mode off --path . \
##       --script res://tests/collision_zorder_parity_test.gd
##
## --xr-mode off is required: without it a modal OpenXR alert hangs the run. The
## "Viewport Texture must be set to use it" errors are expected with no display
## server, not failures.

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


## The facing plane HandPointer would derive from a locked `body` collider.
func _body_plane(body: Node3D) -> Plane:
	var t := body.global_transform
	return Plane(t.basis.z, t.origin)


## Nearest forward ray/plane hit clipped to each window's content quad, mirroring
## a finite collider. Returns the winning SWindow or null.
func _plane_pick(wins: Array, ro: Vector3, rd: Vector3) -> SWindow:
	var best: SWindow = null
	var best_d := INF
	for w in wins:
		var body := w.get_node("Content/StaticBody3D") as Node3D
		var hit = _body_plane(body).intersects_ray(ro, rd)
		if hit == null:
			continue
		var local: Vector3 = hit - body.global_transform.origin
		var half: Vector2 = w.content_size * 0.5
		if absf(local.x) > half.x + EPS or absf(local.y) > half.y + EPS:
			continue
		var d: float = ro.distance_to(hit)
		if d < best_d:
			best_d = d
			best = w
	return best


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
	for w in wm.windows_list.duplicate():
		w.close()
	await process_frame

	# Three windows that partially overlap in X at stepped depth, back to front,
	# so a horizontal sweep crosses the triple overlap, the edges where the front
	# quad drops out, and empty space beyond. Creation order is the z-order:
	# last created is frontmost.
	var y := 1.2
	wm.create_window(Vector3(0.60, y, 0.0))   # back  -> z_order 0
	wm.create_window(Vector3(0.30, y, 0.0))   # mid   -> z_order 1
	wm.create_window(Vector3(0.00, y, 0.0))   # front -> z_order 2
	for i in 6:
		await physics_frame

	# The claim under test is about the content surfaces that z_order stacks.
	# Resize handles are separate colliders that jut IN FRONT of the content
	# plane (HANDLE_Z), and the header sits on its own plane above; both have
	# their own geometry and are not what the depth grid orders. Silence them so
	# the raycast sees exactly the content stack.
	for w in wm.windows_list:
		var header := w.get_node("Header/StaticBody3D") as CollisionObject3D
		header.collision_layer = 0
		var handles := w.get_node_or_null("ResizeHandles")
		if handles:
			for h in handles.get_children():
				(h as CollisionObject3D).collision_layer = 0
	await physics_frame

	var wins := wm.windows_list.duplicate()
	var space := root.world_3d.direct_space_state
	var front: SWindow = wins[-1]
	var eye := Vector3(0.0, y, front.global_position.z + 1.2)

	_report.section("setup")
	_report.check("three fixture windows", wins.size() == 3, str(wins.size()))
	var z_orders := wins.map(func(w): return w.z_order)
	_report.check("distinct z-orders 0,1,2", z_orders == [0, 1, 2], str(z_orders))

	# Sweep the ray across X through all the overlap regions.
	var hits := 0
	var point_ok := 0
	var worst_point := 0.0
	var select_ok := 0
	var select_total := 0
	var z_seen := {}

	var x := -1.2
	while x <= 2.0:
		var target := Vector3(x, y, front.global_position.z)
		var rd := (target - eye).normalized()

		var r := _phys_pick(space, eye, rd)
		if not r.is_empty():
			var win := _window_of(r["collider"])
			if win != null:
				hits += 1
				z_seen[win.z_order] = true

				# Point parity: plane on the physics-hit collider vs its point.
				var body := r["collider"] as Node3D
				var ph = _body_plane(body).intersects_ray(eye, rd)
				if ph != null:
					var gap: float = (ph - r["position"]).length()
					worst_point = maxf(worst_point, gap)
					if gap < EPS:
						point_ok += 1

				# Selection parity: nearest in-bounds plane vs nearest collider.
				select_total += 1
				var picked := _plane_pick(wins, eye, rd)
				if picked == win:
					select_ok += 1
		x += 0.06

	_report.section("coverage")
	# A sweep that only ever hit the front window would pass the parity checks
	# trivially, so assert the edges actually exposed the deeper windows.
	_report.check("physics hit windows", hits > 0, str(hits))
	_report.check("sweep exposed all three z-orders", z_seen.size() == 3,
			str(z_seen.keys()))

	_report.section("point parity")
	_report.check("plane hit equals collision point on the picked window",
			point_ok == hits, "%d/%d" % [point_ok, hits])
	_report.check("worst point gap under eps", worst_point < EPS,
			"%.6f" % worst_point)

	_report.section("z-order selection parity")
	_report.check("nearest in-bounds plane picks the physics window",
			select_ok == select_total, "%d/%d" % [select_ok, select_total])

	_report.finish(self)
