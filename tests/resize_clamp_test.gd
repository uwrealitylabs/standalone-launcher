extends SceneTree
# Verifies that the edge opposite a dragged resize handle stays pinned even when
# the pointer overshoots MIN/MAX_CONTENT_SIZE in a single frame. Run:
#   godot --headless --xr-mode off --script res://tests/resize_clamp_test.gd


const EPS := 0.0001
var _failures := 0


func _check(label: String, cond: bool) -> void:
	if cond:
		print("PASS: " + label)
	else:
		_failures += 1
		print("FAIL: " + label)


func _check_near(label: String, got: float, want: float) -> void:
	_check("%s (got %.5f, want %.5f)" % [label, got, want], absf(got - want) < EPS)


# Builds a PRESSED event with a null (non-hand) pointer, which makes
# _resolve_pointer_hit project the position onto the frozen gesture plane —
# lets the test drive start_resize without a live HandPointer.
func _press_at(win: SWindow, world_pos: Vector3) -> XRToolsPointerEvent:
	return XRToolsPointerEvent.new(
		XRToolsPointerEvent.Type.PRESSED, null, win, world_pos, world_pos)


func _right_edge(win: SWindow) -> float:
	return win.global_position.x + win.content_size.x / 2.0


func _left_edge(win: SWindow) -> float:
	return win.global_position.x - win.content_size.x / 2.0


func _top_edge(win: SWindow) -> float:
	return win.global_position.y + win.content_size.y / 2.0


# One resize gesture: grab `handle` at the window-relative offset `grab`, then
# jump the pointer by `travel` in a single MOVED frame. Returns the window.
func _resize(wm: WindowManager, handle: String, grab: Vector2, travel: Vector2) -> SWindow:
	var win := wm.create_window(Vector3(0.0, 1.2, -2.0))
	var origin: Vector3 = win.global_position
	win.start_resize(handle, _press_at(win, origin + Vector3(grab.x, grab.y, 0.0)))
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
	# ray does in one frame — a small step would land near the limit and hide the
	# bug regardless of whether the shift is derived correctly.
	var past_min_x := (s0.x - SWindow.MIN_CONTENT_SIZE.x) * 3.0
	var past_min_y := (s0.y - SWindow.MIN_CONTENT_SIZE.y) * 3.0
	var past_max_x := (SWindow.MAX_CONTENT_SIZE.x - s0.x) * 3.0
	probe.close()
	await process_frame

	# --- shrink past the minimum in one frame ---
	var w := _resize(wm, "L", Vector2(-hw, 0.0), Vector2(past_min_x, 0.0))
	_check_near("L past min: width clamped", w.content_size.x, SWindow.MIN_CONTENT_SIZE.x)
	_check_near("L past min: right edge pinned", _right_edge(w), 0.0 + hw)

	w = _resize(wm, "R", Vector2(hw, 0.0), Vector2(-past_min_x, 0.0))
	_check_near("R past min: width clamped", w.content_size.x, SWindow.MIN_CONTENT_SIZE.x)
	_check_near("R past min: left edge pinned", _left_edge(w), 0.0 - hw)

	w = _resize(wm, "B", Vector2(0.0, -hh), Vector2(0.0, past_min_y))
	_check_near("B past min: height clamped", w.content_size.y, SWindow.MIN_CONTENT_SIZE.y)
	_check_near("B past min: top edge pinned", _top_edge(w), 1.2 + hh)

	# Clamping x must not freeze the y shift, and vice versa
	w = _resize(wm, "BR", Vector2(hw, -hh), Vector2(-past_min_x, 0.1))
	_check_near("BR x past min: left edge pinned", _left_edge(w), 0.0 - hw)
	_check_near("BR x past min: top edge still pinned", _top_edge(w), 1.2 + hh)

	w = _resize(wm, "BL", Vector2(-hw, -hh), Vector2(past_min_x, 0.1))
	_check_near("BL x past min: right edge pinned", _right_edge(w), 0.0 + hw)
	_check_near("BL x past min: top edge still pinned", _top_edge(w), 1.2 + hh)

	# --- grow past the maximum in one frame ---
	w = _resize(wm, "L", Vector2(-hw, 0.0), Vector2(-past_max_x, 0.0))
	_check_near("L past max: width clamped", w.content_size.x, SWindow.MAX_CONTENT_SIZE.x)
	_check_near("L past max: right edge pinned", _right_edge(w), 0.0 + hw)

	# --- a clamped frame must not poison the frames that follow ---
	w = _resize(wm, "L", Vector2(-hw, 0.0), Vector2(past_min_x, 0.0))
	var origin: Vector3 = Vector3(0.0, 1.2, -2.0)
	w.update_resize(origin + Vector3(-hw + 0.1, 0.0, 0.0))
	_check_near("L recovering: width follows pointer", w.content_size.x, s0.x - 0.1)
	_check_near("L recovering: right edge pinned", _right_edge(w), 0.0 + hw)
	w.stop_resize()
	await process_frame
	_check_near("L after release: right edge pinned", _right_edge(w), 0.0 + hw)

	print("RESULT: %s" % ("ALL PASS" if _failures == 0 else "%d FAILURES" % _failures))
	quit(1 if _failures else 0)
