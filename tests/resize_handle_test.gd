extends SceneTree

## Verifies that the resize handles are reachable by the controller raycasts and
## that a pointer event on one drives a resize.
##
## Run with:
##   godot --headless --xr-mode off --path . \
##       --script res://tests/resize_handle_test.gd
##
## --xr-mode off is required: without an OpenXR runtime, initialization raises a
## modal alert that never gets dismissed and the run hangs.
##
## Adding window.tscn to a headless tree makes the engine print "Viewport
## Texture must be set to use it" — expected output with no display server, not
## a failure.

const Report := preload("res://tests/support/report.gd")

const WINDOW_SCENE := "res://project/windowing/window.tscn"
# Mirrors the RayCast3D collision_mask on both controllers in root.tscn. Written
# out rather than read from SWindow so that a change to one has to be made here
# too; _check_mask_matches_pointers asserts the two still agree.
const POINTER_MASK := 4194304
const EPS := 0.0001

var _report := Report.new()
var _ray: RayCast3D = null


func _initialize() -> void:
	var win: SWindow = load(WINDOW_SCENE).instantiate()
	root.add_child(win)
	_ray = RayCast3D.new()
	_ray.collision_mask = POINTER_MASK
	_ray.target_position = Vector3(0, 0, -2.0)
	root.add_child(_ray)
	await physics_frame
	await physics_frame

	_check_mask_matches_pointers()
	_check_depth_budget(win)
	_check_handles_are_pickable(win)
	_check_content_still_pickable(win)
	_check_border_tiles(win)
	_check_thickness(win, "default size")
	_check_pointer_event_drives_resize(win)
	# Leaves the window at MIN_CONTENT_SIZE, which the check below relies on.
	_check_thickness_shrinks_with_window(win)
	await _check_handles_stay_behind_the_next_window(win)

	_report.finish(self)


## The layer the handles are placed on must be one the controllers' raycasts
## actually look at, or none of the picks below could ever land.
func _check_mask_matches_pointers() -> void:
	_report.section("pointer mask")
	_report.check("HANDLE_COLLISION_LAYER is on the pointers' mask",
			SWindow.HANDLE_COLLISION_LAYER & POINTER_MASK != 0,
			"layer %d vs mask %d" % [SWindow.HANDLE_COLLISION_LAYER, POINTER_MASK])


# Depth budget straight from the constants: forward of the window's own screen,
# and clear of every collider belonging to the window one z-order in front.
func _check_depth_budget(win: SWindow) -> void:
	_report.section("depth budget")
	var front := SWindow.HANDLE_Z + SWindow.HANDLE_DEPTH / 2.0
	var rear := SWindow.HANDLE_Z - SWindow.HANDLE_DEPTH / 2.0
	var screen := _screen_span(win, win.content_3d)

	_report.check("SCREEN_DEPTH %.3f matches the collider the addon builds (%.3f)"
			% [SWindow.SCREEN_DEPTH, screen.y - screen.x],
			absf(screen.y - screen.x - SWindow.SCREEN_DEPTH) < EPS)
	# The addon hangs the box behind the quad, so the whole depth is at or behind
	# the window plane. Anything measuring from a centred box is off by half of it.
	_report.check("the screen collider's front face is the window plane (%+.3f)" % screen.y,
			absf(screen.y) < EPS)

	_report.check("handle front %+.3f is ahead of its own screen front %+.3f"
			% [front, screen.y], front > screen.y)
	_report.check("handle rear %+.3f does not sink into its own screen" % rear,
			rear > screen.y - EPS)
	_report.check("handle front %+.3f clears the next window's screen rear %+.3f"
			% [front, SWindow.Z_STEP + screen.x], front < SWindow.Z_STEP + screen.x)
	_report.check("handle front %+.3f clears the next window's handle rear %+.3f"
			% [front, SWindow.Z_STEP + rear], front < SWindow.Z_STEP + rear)


## Rear and front z of `part`'s screen collider, in `win`-local space.
func _screen_span(win: SWindow, part: Node3D) -> Vector2:
	var col := part.get_node("StaticBody3D/CollisionShape3D") as CollisionShape3D
	var depth: float = (col.shape as BoxShape3D).size.z
	var centre: float = win.to_local(col.global_position).z
	return Vector2(centre - depth / 2.0, centre + depth / 2.0)


## Every handle must be a body a real raycast on the pointers' own mask can
## hit: an Area3D, or a body left off that layer, is invisible to the pointers
## however correct its geometry is.
func _check_handles_are_pickable(win: SWindow) -> void:
	_report.section("handles are pickable")
	for handle_id in ["L", "R", "B", "BL", "BR"]:
		var body := _handle(win, handle_id)
		if body == null:
			_report.check("handle %s exists" % handle_id, false)
			continue
		var hit := _cast_at(body.global_position)
		_report.check("ray hits handle %s (got %s)" % [handle_id, _describe(hit)], hit == body)


func _check_content_still_pickable(win: SWindow) -> void:
	_report.section("the content is still pickable")
	var hit := _cast_at(win.content_3d.global_position)
	var content_body := win.content_3d.get_node("StaticBody3D")
	_report.check("ray at the window centre still hits the content (got %s)" % _describe(hit),
			hit == content_body)


## Asserts each band is as thick as the constants call for at the window's
## current size: a fraction of the side it runs along, capped so a large window
## does not get an unusably wide border.
##
## The default size caps the vertical bands at HANDLE_MAX_THICKNESS while the
## bottom band is still on the ratio; at MIN_CONTENT_SIZE both are on the ratio,
## so the two calls cover both sides of the cap.
func _check_thickness(win: SWindow, label: String) -> void:
	var want_tx := minf(SWindow.HANDLE_MAX_THICKNESS,
			win.content_size.x * SWindow.HANDLE_THICKNESS_RATIO)
	var want_ty := minf(SWindow.HANDLE_MAX_THICKNESS,
			win.content_size.y * SWindow.HANDLE_THICKNESS_RATIO)
	_report.section("band thickness at %s" % label)
	_report.near("L/R thickness", _box(win, "R").size.x, want_tx, EPS)
	_report.near("B thickness", _box(win, "B").size.y, want_ty, EPS)


## Drives a whole resize through the pointer_event signal the handles carry,
## from the press that starts the gesture to the release that ends it.
func _check_pointer_event_drives_resize(win: SWindow) -> void:
	_report.section("a pointer event drives a resize")
	var before: Vector2 = win.content_size
	var right := _handle(win, "R")
	var grab := right.global_position
	_emit(right, XRToolsPointerEvent.Type.PRESSED, grab)
	_report.check("PRESSED on the R handle starts a resize", win._resizing)
	_report.check("the started resize is the R handle", win._resize_handle == "R")

	_emit(right, XRToolsPointerEvent.Type.MOVED, grab + Vector3(0.3, 0, 0))
	_report.check("MOVED on the R handle widens the window by 0.3 (got %.4f)"
			% (win.content_size.x - before.x),
			absf(win.content_size.x - before.x - 0.3) < EPS)
	_report.check("the R handle followed the new edge",
			absf(right.position.x - win.content_size.x / 2.0) < EPS)

	_emit(right, XRToolsPointerEvent.Type.RELEASED, grab + Vector3(0.3, 0, 0))
	_report.check("RELEASED on the R handle ends the resize", not win._resizing)


## Shrinks the window to MIN_CONTENT_SIZE and rechecks the bands, which must
## have shrunk with it. Leaves the window at that size.
func _check_thickness_shrinks_with_window(win: SWindow) -> void:
	_report.section("shrink to the minimum")
	# The bottom-left corner is the only handle that drives both axes inward
	var corner := _handle(win, "BL")
	var grab := corner.global_position
	_emit(corner, XRToolsPointerEvent.Type.PRESSED, grab)
	_emit(corner, XRToolsPointerEvent.Type.MOVED, grab + Vector3(9.0, 9.0, 0))
	_emit(corner, XRToolsPointerEvent.Type.RELEASED, grab + Vector3(9.0, 9.0, 0))
	_report.check("window clamped to MIN_CONTENT_SIZE (got %s)" % win.content_size,
			win.content_size.is_equal_approx(SWindow.MIN_CONTENT_SIZE))
	_check_thickness(win, "min size")


# The five bands must cover the border with no seam a press can fall through
# and no overlap that would leave two handles competing at the same depth.
func _check_border_tiles(win: SWindow) -> void:
	_report.section("the bands tile the border")
	var l := _rect(win, "L")
	var r := _rect(win, "R")
	var b := _rect(win, "B")
	var bl := _rect(win, "BL")
	var br := _rect(win, "BR")

	_report.check("L meets BL with no seam (%.4f == %.4f)" % [l.position.y, bl.end.y],
			absf(l.position.y - bl.end.y) < EPS)
	_report.check("R meets BR with no seam (%.4f == %.4f)" % [r.position.y, br.end.y],
			absf(r.position.y - br.end.y) < EPS)
	_report.check("B meets BL with no seam (%.4f == %.4f)" % [b.position.x, bl.end.x],
			absf(b.position.x - bl.end.x) < EPS)
	_report.check("B meets BR with no seam (%.4f == %.4f)" % [b.end.x, br.position.x],
			absf(b.end.x - br.position.x) < EPS)

	for pair in [["L", l, "BL", bl], ["R", r, "BR", br], ["B", b, "BL", bl],
			["B", b, "BR", br], ["L", l, "B", b], ["R", r, "B", b]]:
		var a: Rect2 = pair[1]
		var c: Rect2 = pair[3]
		var overlap := a.intersection(c)
		_report.check("%s and %s do not overlap (%.5f m2)" % [pair[0], pair[2], overlap.get_area()],
				overlap.get_area() < EPS)

	# Corners reach the far side of both edges they join
	var hh: float = win.content_size.y / 2.0
	_report.check("L reaches the top of the content (%.4f == %.4f)" % [l.end.y, hh],
			absf(l.end.y - hh) < EPS)
	_report.check("R reaches the top of the content (%.4f == %.4f)" % [r.end.y, hh],
			absf(r.end.y - hh) < EPS)


## A window's handles reach forward of its own screen, so they must still fall
## short of the screen belonging to the window one z-order in front of it.
##
## Expects `back` to be at MIN_CONTENT_SIZE, so that the fresh default-sized
## window placed in front of it is the larger of the two.
func _check_handles_stay_behind_the_next_window(back: SWindow) -> void:
	_report.section("handles stay behind the next window")
	var front: SWindow = load(WINDOW_SCENE).instantiate()
	root.add_child(front)
	await physics_frame

	back.z_order = 0
	back.apply_z_order()
	front.z_order = 1
	front.apply_z_order()
	front.global_position.x = back.global_position.x
	front.global_position.y = back.global_position.y
	await physics_frame
	await physics_frame

	_report.check("the front window is one Z_STEP ahead (%.4f)"
			% (front.global_position.z - back.global_position.z),
			absf(front.global_position.z - back.global_position.z - SWindow.Z_STEP) < EPS)

	# Only a smaller window behind a larger one puts the back border over the
	# front screen, which is the arrangement where a bad pick would bite
	_report.check("the back window is the smaller of the two (%s vs %s)"
			% [back.content_size, front.content_size],
			back.content_size.x < front.content_size.x
			and back.content_size.y < front.content_size.y)

	# Aim where the back window's handles are; the front window's screen covers
	# the same spot and is nearer, so it must take the ray.
	for handle_id in ["L", "R", "B", "BL", "BR"]:
		var behind := _handle(back, handle_id)
		var hit := _cast_at(behind.global_position)
		var owner_win := _owning_window(hit)
		_report.check("ray over the back window's %s handle hits the front window (got %s)"
				% [handle_id, _describe(hit)], owner_win == front)

	front.free()


## The SWindow that `node` belongs to, or null.
func _owning_window(node: Object) -> SWindow:
	var walk := node as Node
	while walk != null:
		if walk is SWindow:
			return walk
		walk = walk.get_parent()
	return null


func _rect(win: SWindow, handle_id: String) -> Rect2:
	var body := _handle(win, handle_id)
	var size := _box(win, handle_id).size
	return Rect2(body.position.x - size.x / 2.0, body.position.y - size.y / 2.0,
			size.x, size.y)


func _emit(body: StaticBody3D, type: int, pos: Vector3) -> void:
	body.emit_signal("pointer_event",
			XRToolsPointerEvent.new(type, null, body, pos, pos))


## Collider the pointer mask sees first at `world_pos`, or null for a miss.
func _cast_at(world_pos: Vector3) -> Object:
	_ray.global_position = world_pos + Vector3(0, 0, 1.0)
	_ray.force_raycast_update()
	return _ray.get_collider() if _ray.is_colliding() else null


func _handle(win: SWindow, handle_id: String) -> StaticBody3D:
	var handles := win.get_node_or_null("ResizeHandles")
	if handles == null:
		return null
	for child in handles.get_children():
		if child.get_meta("handle_id", "") == handle_id:
			return child as StaticBody3D
	return null


func _box(win: SWindow, handle_id: String) -> BoxShape3D:
	var col := _handle(win, handle_id).get_child(0) as CollisionShape3D
	return col.shape as BoxShape3D


func _describe(node: Object) -> String:
	if node == null:
		return "nothing"
	return (node as Node).get_path()

