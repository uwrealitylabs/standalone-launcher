extends SceneTree

## Verifies that the edge opposite a dragged resize handle stays pinned even
## when the pointer overshoots MIN/MAX_CONTENT_SIZE in a single frame.
##
## Past a clamp the pointer keeps moving while the size does not, so the
## window's position shift has to be derived from the size actually applied
## rather than from the pointer delta. Run with:
##   godot --headless --xr-mode off --path . \
##       --script res://tests/resize_clamp_test.gd
##
## --xr-mode off is required: without an OpenXR runtime, initialization raises a
## modal alert that never gets dismissed and the run hangs.
##
## Adding window.tscn to a headless tree makes the engine print "Viewport
## Texture must be set to use it" — expected output with no display server, not
## a failure.

const Report := preload("res://tests/support/report.gd")
const Fixtures := preload("res://tests/support/window_fixtures.gd")

var _report := Report.new()


func _right_edge(win: SWindow) -> float:
	return win.global_position.x + win.content_size.x / 2.0


func _left_edge(win: SWindow) -> float:
	return win.global_position.x - win.content_size.x / 2.0


func _top_edge(win: SWindow) -> float:
	return win.global_position.y + win.content_size.y / 2.0


## Runs one resize gesture on a fresh window: grabs `handle` at the
## window-relative offset `grab`, then jumps the pointer by `travel` in a single
## MOVED frame. Returns the window, left mid-gesture.
func _resize(wm: WindowManager, handle: String, grab: Vector2, travel: Vector2) -> SWindow:
	var win := wm.create_window(Vector3(0.0, 1.2, -2.0))
	var origin: Vector3 = win.global_position
	win.start_resize(handle, Fixtures.press_at(win, origin + Vector3(grab.x, grab.y, 0.0)))
	win.update_resize(origin + Vector3(grab.x + travel.x, grab.y + travel.y, 0.0))
	return win


func _initialize() -> void:
	var wm_scene: PackedScene = load("res://project/windowing/window_manager.tscn")
	var wm: WindowManager = wm_scene.instantiate()
	root.add_child(wm)
	await process_frame

	var probe := wm.create_window(Vector3(0.0, 1.2, -2.0))
	await process_frame
	var s0: Vector2 = probe.content_size
	var hw := s0.x / 2.0
	var hh := s0.y / 2.0
	# The overshoot has to clear the clamp by a wide margin, which is what a fast
	# ray does in one frame — a small step would land near the limit and pass
	# whether or not the shift is derived correctly.
	var past_min_x := (s0.x - SWindow.MIN_CONTENT_SIZE.x) * 3.0
	var past_min_y := (s0.y - SWindow.MIN_CONTENT_SIZE.y) * 3.0
	var past_max_x := (SWindow.MAX_CONTENT_SIZE.x - s0.x) * 3.0
	probe.close()
	await process_frame

	_report.section("shrink past the minimum in one frame")
	var w := _resize(wm, "L", Vector2(-hw, 0.0), Vector2(past_min_x, 0.0))
	_report.near("L: width clamped", w.content_size.x, SWindow.MIN_CONTENT_SIZE.x)
	_report.near("L: right edge pinned", _right_edge(w), 0.0 + hw)

	w = _resize(wm, "R", Vector2(hw, 0.0), Vector2(-past_min_x, 0.0))
	_report.near("R: width clamped", w.content_size.x, SWindow.MIN_CONTENT_SIZE.x)
	_report.near("R: left edge pinned", _left_edge(w), 0.0 - hw)

	w = _resize(wm, "B", Vector2(0.0, -hh), Vector2(0.0, past_min_y))
	_report.near("B: height clamped", w.content_size.y, SWindow.MIN_CONTENT_SIZE.y)
	_report.near("B: top edge pinned", _top_edge(w), 1.2 + hh)

	# A corner drives both axes, so clamping one must leave the other's shift
	# free to keep tracking the pointer.
	_report.section("one axis clamped, the other still moving")
	w = _resize(wm, "BR", Vector2(hw, -hh), Vector2(-past_min_x, 0.1))
	_report.near("BR: left edge pinned", _left_edge(w), 0.0 - hw)
	_report.near("BR: top edge still pinned", _top_edge(w), 1.2 + hh)

	w = _resize(wm, "BL", Vector2(-hw, -hh), Vector2(past_min_x, 0.1))
	_report.near("BL: right edge pinned", _right_edge(w), 0.0 + hw)
	_report.near("BL: top edge still pinned", _top_edge(w), 1.2 + hh)

	_report.section("grow past the maximum in one frame")
	w = _resize(wm, "L", Vector2(-hw, 0.0), Vector2(-past_max_x, 0.0))
	_report.near("L: width clamped", w.content_size.x, SWindow.MAX_CONTENT_SIZE.x)
	_report.near("L: right edge pinned", _right_edge(w), 0.0 + hw)

	# The gesture baseline is frozen at grab time, so a frame spent clamped must
	# leave no residue in the frames that follow it.
	_report.section("recovering from a clamped frame")
	w = _resize(wm, "L", Vector2(-hw, 0.0), Vector2(past_min_x, 0.0))
	var origin := Vector3(0.0, 1.2, -2.0)
	w.update_resize(origin + Vector3(-hw + 0.1, 0.0, 0.0))
	_report.near("width follows the pointer again", w.content_size.x, s0.x - 0.1)
	_report.near("right edge pinned", _right_edge(w), 0.0 + hw)
	w.stop_resize()
	await process_frame
	_report.near("right edge pinned after release", _right_edge(w), 0.0 + hw)

	_report.finish(self)
