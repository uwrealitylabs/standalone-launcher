extends SceneTree

## Verifies the pointer's two depth sources agree ON the collider.
##
## HandPointer selects a target with a physics raycast (a finite collider) but
## then computes the gesture position by intersecting the ray with that target's
## facing plane (`_locked_plane_hit`). The plane is only sound as a stand-in for
## the collision point because each content collider is a thin box hung BEHIND
## the quad, so its front face lands on `Plane(body.basis.z, body.origin)`. This
## suite pins that contract: over a ray sweep across the docked windows, the
## ray/plane hit on the physics-picked content collider equals the collision
## point (same landing point, so same depth). If the collider offset drifts so
## the front face no longer sits on that plane, the point check fails.
##
## Why the plane is kept, and must not be "simplified" away in favour of the
## collision point: this parity holds ON the collider only. During a press
## Wayland holds an implicit grab, so motion and the release must keep reaching
## the pressed surface even after the ray leaves the collider — exactly where the
## raycast returns nothing and only the infinite plane still yields a coordinate.
## Header drag and resize need the same off-collider continuation. So the design
## is a deliberate split: the collision point drives unpressed hover (its hit/miss
## is the natural enter/leave edge, and the raycast runs anyway to select which
## window is under the ray), and the plane drives press-through-release. This
## test's on-collider agreement is what makes that handoff seamless; it is NOT a
## licence to collapse the two sources into one.
##
## Scope: the point-parity property is per-collider and needs no window overlap,
## so the fixture is just the three docked slot windows the manager places on its
## arc (LEFT/CENTRE/RIGHT). The windows sit at stepped azimuth, each turned to
## face the arc's reference point, and the sweep casts from that reference point
## so every window is crossed head-on.
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

	# Fill all three slots (CENTRE, then RIGHT, then LEFT). Bare colliders are
	# enough: the point-parity claim is about the content box geometry, not what
	# renders in it, so no content scene is loaded.
	wm.create_window()
	wm.create_window()
	wm.create_window()
	for i in 6:
		await physics_frame

	# The claim under test is about the content surfaces. Resize handles are
	# separate colliders that jut IN FRONT of the content plane (HANDLE_Z), and
	# the header sits on its own plane above; both have their own geometry with a
	# front face off the content plane. Silence them so the raycast sees exactly
	# the content box whose front face the plane models.
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
	# Cast from the arc's reference point: every slot centre sits on the arc at
	# that radius, turned to face back here, so a horizontal azimuth sweep crosses
	# each window head-on.
	var eye := wm.reference_point

	_report.section("setup")
	_report.check("three fixture windows", wins.size() == 3, str(wins.size()))

	# Sweep the ray direction in azimuth across the arc. The three default
	# windows span roughly [-63, +63] degrees from the reference point, so a
	# slightly wider sweep crosses all three with gaps between them.
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
