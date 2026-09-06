extends SceneTree

## Verifies that the resize handles are reachable by the controller raycasts and
## that a pointer event on one drives a resize.
##
## Run with:
##   godot --headless --xr-mode off --path . \
##       --script res://tests/resize_handle_test.gd
##
## --xr-mode off is required: without it a modal OpenXR alert hangs the run.
##
## The "Viewport Texture must be set to use it" errors are expected with no
## display server, not failures.

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
	_check_resize_plane_is_window_surface(win)
	_check_handles_are_pickable(win)
	_check_content_still_pickable(win)
	_check_border_tiles(win)
	_check_thickness(win, "default size")
	_check_pointer_event_drives_resize(win)
	_check_resize_survives_window_move(win)
	_check_thickness_shrinks_with_window(win)
	_check_affordance_visibility(win)

	_report.finish(self)


## The layer the handles are placed on must be one the controllers' raycasts
## actually look at, or none of the picks below could ever land.
func _check_mask_matches_pointers() -> void:
	_report.section("pointer mask")
	_report.check("HANDLE_COLLISION_LAYER is on the pointers' mask",
			SWindow.HANDLE_COLLISION_LAYER & POINTER_MASK != 0,
			"layer %d vs mask %d" % [SWindow.HANDLE_COLLISION_LAYER, POINTER_MASK])


# Depth budget straight from the constants: the handles sit forward of the
# window's own screen without sinking into it. Windows occupy separate slots on
# the arc, so there is no stacked neighbour to clear.
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


## The handle collider extends in front for picking, but resize motion is
## projected onto the visible window surface rather than the collider's centre.
func _check_resize_plane_is_window_surface(win: SWindow) -> void:
	_report.section("resize plane")
	var plane := win._live_resize_plane()
	var xf := win.global_transform.orthonormalized()
	var handle_centre := xf.origin + xf.basis.z * SWindow.HANDLE_Z

	_report.check("the resize plane passes through the visible window surface",
			absf(plane.distance_to(xf.origin)) < EPS)
	_report.check("the resize plane faces along the window normal",
			plane.normal.is_equal_approx(xf.basis.z))
	_report.check("the handle collider centre remains in front of the resize plane",
			absf(plane.distance_to(handle_centre) - SWindow.HANDLE_Z) < EPS)


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
## does not get an unusably wide border. Call at both a capped and an uncapped
## size to cover the cap.
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

	# Fixed-centre resize: the grabbed edge follows the pointer while the opposite
	# edge moves by the same amount, so a 0.3 m displacement widens the window by
	# 0.6 m.
	_emit(right, XRToolsPointerEvent.Type.MOVED, grab + Vector3(0.3, 0, 0))
	_report.check("MOVED on the R handle widens the window by 0.6 (got %.4f)"
			% (win.content_size.x - before.x),
			absf(win.content_size.x - before.x - 0.6) < EPS)
	_report.check("the R handle followed the new edge",
			absf(right.position.x - win.content_size.x / 2.0) < EPS)

	_emit(right, XRToolsPointerEvent.Type.RELEASED, grab + Vector3(0.3, 0, 0))
	_report.check("RELEASED on the R handle ends the resize", not win._resizing)


## The gesture is measured in the window's own frame, so moving the window
## mid-resize -- as locomotion does, sliding the whole arc via WindowFollow -- must
## not change the size on its own. Grab, translate the window (and the pointer with
## it, as the rig carries both), and confirm the size holds; then a genuine drag on
## top of the move still resizes correctly.
func _check_resize_survives_window_move(win: SWindow) -> void:
	_report.section("a mid-gesture window move does not corrupt the resize")
	var before: Vector2 = win.content_size
	var start_pos: Vector3 = win.global_position
	var right := _handle(win, "R")
	var grab := right.global_position
	_emit(right, XRToolsPointerEvent.Type.PRESSED, grab)

	# Locomotion slides the window; the hand rides the same rig, so the pointer
	# shifts by the identical world vector. Net pointer-vs-window motion is zero.
	var shift := Vector3(2.0, 0.5, 0)
	win.global_position += shift
	_emit(right, XRToolsPointerEvent.Type.MOVED, grab + shift)
	_report.check("a pure window move leaves the size unchanged (dx %.4f)"
			% (win.content_size.x - before.x),
			win.content_size.is_equal_approx(before))

	# A real 0.3 m drag on top of the moved window still widens it by 0.6 m.
	_emit(right, XRToolsPointerEvent.Type.MOVED, grab + shift + Vector3(0.3, 0, 0))
	_report.check("a drag after the move still widens by 0.6 (got %.4f)"
			% (win.content_size.x - before.x),
			absf(win.content_size.x - before.x - 0.6) < EPS)

	_emit(right, XRToolsPointerEvent.Type.RELEASED, grab + shift + Vector3(0.3, 0, 0))
	# Leave the window as the following tests expect it: original pose and size.
	win.global_position = start_pos
	win.resize(before)


## The affordance marks are driven purely by hover: an ENTERED shows the hovered
## handle's mark and only an EXITED hides it. A resize does not change that, so
## the mark stays up through the gesture and remains after release while the ray
## is still on the handle. Hovers are counted per pointer, so with two rays the
## mark persists until the last one leaves. There is no top mark, matching the
## missing top handle.
func _check_affordance_visibility(win: SWindow) -> void:
	_report.section("resize affordances")
	_report.check("there is no top affordance",
			_affordance(win, "T") == null and _affordance(win, "TOP") == null)

	var right := _handle(win, "R")
	var mark := _affordance(win, "R")
	if mark == null:
		_report.check("the R affordance exists", false)
		return
	_report.check("affordances start hidden", not mark.visible)

	_emit(right, XRToolsPointerEvent.Type.ENTERED, right.global_position)
	_report.check("entering the R handle shows its mark", mark.visible)

	# The mark stays up across the whole gesture, not just the hover before it.
	var grab := right.global_position
	_emit(right, XRToolsPointerEvent.Type.PRESSED, grab)
	_emit(right, XRToolsPointerEvent.Type.MOVED, grab + Vector3(0.1, 0, 0))
	_report.check("the mark stays shown during the resize", mark.visible)

	# The ray is still on the handle after release, so the mark stays shown; no
	# exit-and-re-enter is needed to bring it back.
	_emit(right, XRToolsPointerEvent.Type.RELEASED, grab + Vector3(0.1, 0, 0))
	_report.check("the mark stays shown after the resize ends", mark.visible)

	# Only leaving the handle hides it.
	_emit(right, XRToolsPointerEvent.Type.EXITED, right.global_position)
	_report.check("exiting the handle hides the mark", not mark.visible)

	# Two rays on one handle: the mark must persist until the last leaves. This is
	# the reported case -- the non-resizing ray slides off the edge mid-resize
	# while the resizing ray is still on the handle.
	var ray_a := Node3D.new()
	var ray_b := Node3D.new()
	_emit_from(right, XRToolsPointerEvent.Type.ENTERED, right.global_position, ray_a)
	_emit_from(right, XRToolsPointerEvent.Type.PRESSED, grab, ray_a)
	_emit_from(right, XRToolsPointerEvent.Type.ENTERED, right.global_position, ray_b)
	_report.check("two rays on the handle show the mark", mark.visible)

	_emit_from(right, XRToolsPointerEvent.Type.EXITED, right.global_position, ray_b)
	_report.check("the mark stays while the resizing ray still hovers", mark.visible)
	_emit_from(right, XRToolsPointerEvent.Type.RELEASED, grab, ray_a)
	_report.check("the mark stays after release while a ray is on it", mark.visible)

	_emit_from(right, XRToolsPointerEvent.Type.EXITED, right.global_position, ray_a)
	_report.check("the mark hides once the last ray leaves", not mark.visible)
	ray_a.free()
	ray_b.free()


## The affordance group `win` shows for `handle_id`, or null if it has none.
func _affordance(win: SWindow, handle_id: String) -> Node3D:
	var root := win.get_node_or_null("ResizeAffordances")
	if root == null:
		return null
	return root.get_node_or_null("Affordance" + handle_id) as Node3D


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


func _rect(win: SWindow, handle_id: String) -> Rect2:
	var body := _handle(win, handle_id)
	var size := _box(win, handle_id).size
	return Rect2(body.position.x - size.x / 2.0, body.position.y - size.y / 2.0,
			size.x, size.y)


func _emit(body: StaticBody3D, type: int, pos: Vector3) -> void:
	_emit_from(body, type, pos, null)


## Emits a handle event carrying `pointer`, so a test can act as more than one
## controller by passing distinct pointer nodes.
func _emit_from(body: StaticBody3D, type: int, pos: Vector3, pointer: Node3D) -> void:
	body.emit_signal("pointer_event",
			XRToolsPointerEvent.new(type, pointer, body, pos, pos))


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
