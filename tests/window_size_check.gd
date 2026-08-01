extends SceneTree

## Verifies that SWindow._apply_size keeps every size-dependent part in sync.
##
## Runs the window in a live tree so _ready and the resize gesture path both
## execute. Run with:
##   godot --headless --path . --script res://tests/window_size_check.gd

const WINDOW_SCENE := "res://project/windowing/window.tscn"
const EPS := 0.001

var _failures := 0


func _initialize() -> void:
	var win: SWindow = load(WINDOW_SCENE).instantiate()
	root.add_child(win)
	await process_frame

	print("[seeded from scene]")
	_check("content_size seeded from content screen_size",
			win.content_size.is_equal_approx(Vector2(1.5, 0.75)), str(win.content_size))
	_check("PIXELS_PER_UNIT seeded from scene", absf(win.PIXELS_PER_UNIT - 400.0 / 1.5) < 0.1,
			str(win.PIXELS_PER_UNIT))
	_check("HEADER_PIXELS_PER_UNIT seeded from scene",
			absf(win.HEADER_PIXELS_PER_UNIT - 399.93 / 1.5) < 0.1, str(win.HEADER_PIXELS_PER_UNIT))
	_check_invariant(win)

	# --- live phase: screens track every frame, resolution waits for the clock ---
	var before_content_res: Vector2 = win.content_3d.viewport_size
	var before_header_res: Vector2 = win.header_3d.viewport_size
	win.start_resize("R", _press_at(win, win.global_position))
	win.update_resize(win.global_position + Vector3(0.4, 0, 0))
	win._process(0.001)

	print("[mid-gesture, inside the commit interval]")
	_check("content grew to 1.9 wide", absf(win.content_size.x - 1.9) < EPS, str(win.content_size))
	_check_screens_agree(win)
	_check("content resolution waits for the interval",
			win.content_3d.viewport_size.is_equal_approx(before_content_res),
			str(win.content_3d.viewport_size))
	_check("header resolution waits for the interval",
			win.header_3d.viewport_size.is_equal_approx(before_header_res),
			str(win.header_3d.viewport_size))

	# --- pointer stops moving but never releases: the clock must still catch up ---
	win._process(SWindow.MIN_COMMIT_INTERVAL)

	print("[held still past the interval]")
	_check("content resolution caught up without a release",
			not win.content_3d.viewport_size.is_equal_approx(before_content_res),
			str(win.content_3d.viewport_size))
	_check("header resolution caught up without a release",
			not win.header_3d.viewport_size.is_equal_approx(before_header_res),
			str(win.header_3d.viewport_size))
	_check_resolutions_agree(win)
	_check("no stretch left after a commit", _stretch(win) < EPS, "%.4f" % _stretch(win))

	# --- a nudge below the tolerance must not earn a reallocation ---
	var settled_res: Vector2 = win.content_3d.viewport_size
	win.update_resize(win.global_position + Vector3(0.41, 0, 0))
	win._process(1.0)

	print("[sub-tolerance nudge]")
	_check("0.5% growth does not earn a reallocation",
			win.content_3d.viewport_size.is_equal_approx(settled_res),
			str(win.content_3d.viewport_size))

	# --- release: everything settles exactly, whatever the throttle last did ---
	win.stop_resize()
	await process_frame

	print("[after release]")
	_check("content resolution updated",
			not win.content_3d.viewport_size.is_equal_approx(before_content_res),
			str(win.content_3d.viewport_size))
	_check_invariant(win)

	# --- slow drag: the interval never binds, so the stretch gate governs ---
	print("[slow drag: stretch gate governs]")
	var slow := _drag(win, -0.3, 3.0, 270)
	print("       worst stretch %.2f%%, %d commit(s) over 270 frames"
			% [slow.stretch * 100.0, slow.commits])
	_check("stretch stays within tolerance",
			slow.stretch <= SWindow.MAX_STRETCH + 0.005, "%.4f" % slow.stretch)
	_check("gate still allows some commits", slow.commits > 0, "%d" % slow.commits)
	_check_invariant(win)

	# --- fast drag: the stretch gate saturates, so the interval caps the cost ---
	print("[fast drag: interval gate governs]")
	var fast := _drag(win, 1.3, 0.5, 45)
	var ceiling := int(ceil(0.5 / SWindow.MIN_COMMIT_INTERVAL)) + 1
	print("       worst stretch %.2f%%, %d commit(s) over 45 frames"
			% [fast.stretch * 100.0, fast.commits])
	_check("commits stay under the rate ceiling", fast.commits <= ceiling,
			"%d commits, ceiling %d" % [fast.commits, ceiling])
	_check_invariant(win)

	# --- clamping ---
	win.start_resize("R", _press_at(win, win.global_position + Vector3(0.95, 0, 0)))
	win.update_resize(win.global_position + Vector3(9.0, 0, 0))
	win.stop_resize()
	await process_frame

	print("[clamped to MAX_CONTENT_SIZE]")
	_check("content width clamped", absf(win.content_size.x - SWindow.MAX_CONTENT_SIZE.x) < EPS,
			str(win.content_size))
	_check_invariant(win)

	print("")
	if _failures == 0:
		print("PASS - all checks passed")
		quit(0)
	else:
		print("FAIL - %d check(s) failed" % _failures)
		quit(1)


## Full contract: screens, resolutions, header placement, resource separation.
func _check_invariant(win: SWindow) -> void:
	_check_screens_agree(win)
	_check_resolutions_agree(win)

	var expected_y: float = (win.content_size.y + SWindow.HEADER_HEIGHT) / 2.0
	_check("header sits above content", absf(win.header_3d.position.y - expected_y) < EPS,
			"%.5f vs %.5f" % [win.header_3d.position.y, expected_y])

	var header_bottom: float = win.header_3d.position.y - SWindow.HEADER_HEIGHT / 2.0
	var content_top: float = win.content_3d.position.y + win.content_size.y / 2.0
	_check("no seam between header and content", absf(header_bottom - content_top) < EPS,
			"%.5f vs %.5f" % [header_bottom, content_top])

	_check("header and content own separate meshes",
			_mesh(win, "Header").get_instance_id() != _mesh(win, "Content").get_instance_id())
	_check("header and content own separate shapes",
			_shape(win, "Header").get_instance_id() != _shape(win, "Content").get_instance_id())

	var handles := win.get_node_or_null("ResizeHandles")
	_check("resize handles exist", handles != null and handles.get_child_count() == 5,
			"%d handle(s)" % (handles.get_child_count() if handles else -1))
	if handles:
		var right := _handle(handles, "R")
		_check("R handle on the content edge",
				right != null and absf(right.position.x - win.content_size.x / 2.0) < EPS,
				str(right.position) if right else "missing")


## Asserts each surface's mesh, collision shape and world-to-viewport
## translator all describe the same physical screen.
func _check_screens_agree(win: SWindow) -> void:
	var content := win.content_size
	var header := Vector2(win.content_size.x, SWindow.HEADER_HEIGHT)

	_check("content mesh == content_size", _mesh(win, "Content").size.is_equal_approx(content),
			str(_mesh(win, "Content").size))
	_check("content shape == content_size",
			_shape(win, "Content").size.is_equal_approx(Vector3(content.x, content.y, 0.02)),
			str(_shape(win, "Content").size))
	_check("content screen_size == content_size", win.content_3d.screen_size.is_equal_approx(content),
			str(win.content_3d.screen_size))
	_check("content body translator == content_size",
			_body(win, "Content").screen_size.is_equal_approx(content),
			str(_body(win, "Content").screen_size))

	_check("header mesh == header size", _mesh(win, "Header").size.is_equal_approx(header),
			str(_mesh(win, "Header").size))
	_check("header shape == header size",
			_shape(win, "Header").size.is_equal_approx(Vector3(header.x, header.y, 0.02)),
			str(_shape(win, "Header").size))
	_check("header screen_size == header size", win.header_3d.screen_size.is_equal_approx(header),
			str(win.header_3d.screen_size))
	_check("header body translator == header size",
			_body(win, "Header").screen_size.is_equal_approx(header),
			str(_body(win, "Header").screen_size))


## Asserts each surface's render resolution matches its screen at the window's
## pixel density, and that the SubViewport and the body's translator agree.
func _check_resolutions_agree(win: SWindow) -> void:
	var content := win.content_size
	var header := Vector2(win.content_size.x, SWindow.HEADER_HEIGHT)
	var want_content := _expected_res(content, win.PIXELS_PER_UNIT)
	var want_header := _expected_res(header, win.HEADER_PIXELS_PER_UNIT)

	_check("content viewport_size == size x ppu",
			win.content_3d.viewport_size.is_equal_approx(want_content),
			"%s vs %s" % [win.content_3d.viewport_size, want_content])
	_check("content SubViewport matches",
			_viewport(win, "Content").size == Vector2i(want_content),
			str(_viewport(win, "Content").size))
	_check("content body resolution matches",
			_body(win, "Content").viewport_size.is_equal_approx(want_content),
			str(_body(win, "Content").viewport_size))

	_check("header viewport_size == size x ppu",
			win.header_3d.viewport_size.is_equal_approx(want_header),
			"%s vs %s" % [win.header_3d.viewport_size, want_header])
	_check("header SubViewport matches",
			_viewport(win, "Header").size == Vector2i(want_header),
			str(_viewport(win, "Header").size))
	_check("header body resolution matches",
			_body(win, "Header").viewport_size.is_equal_approx(want_header),
			str(_body(win, "Header").viewport_size))

	_check("content aspect matches screen aspect",
			absf(want_content.x / want_content.y - content.x / content.y) < 0.01,
			"%.4f vs %.4f" % [want_content.x / want_content.y, content.x / content.y])


## Drives a whole resize gesture that changes the content width by `grow` world
## units over `seconds` of simulated time, ticking the throttle clock by hand so
## the result does not depend on the host's frame rate. Reports the worst stretch
## seen and how many times the render target was reallocated.
func _drag(win: SWindow, grow: float, seconds: float, frames: int) -> Dictionary:
	win.start_resize("R", _press_at(win, win.global_position))
	var dt := seconds / float(frames)
	var last_res: Vector2 = win.content_3d.viewport_size
	var commits := 0
	var worst := 0.0
	for i in frames:
		win.update_resize(win.global_position + Vector3(grow * float(i + 1) / frames, 0, 0))
		win._process(dt)
		worst = maxf(worst, _stretch(win))
		if not win.content_3d.viewport_size.is_equal_approx(last_res):
			commits += 1
			last_res = win.content_3d.viewport_size
	win.stop_resize()
	return {"stretch": worst, "commits": commits}


## Worst-axis discrepancy between the size the screen now measures and the size
## its render target was allocated for — what shows up as stretched text.
func _stretch(win: SWindow) -> float:
	return maxf(absf(win.content_size.x / win._res_basis.x - 1.0),
			absf(win.content_size.y / win._res_basis.y - 1.0))


func _expected_res(size: Vector2, ppu: float) -> Vector2:
	return Vector2(maxf(1.0, roundf(size.x * ppu)), maxf(1.0, roundf(size.y * ppu)))


# Null pointer makes _resolve_pointer_hit project onto the frozen gesture
# plane, which lets the test drive a resize without a live HandPointer.
func _press_at(win: SWindow, world_pos: Vector3) -> XRToolsPointerEvent:
	return XRToolsPointerEvent.new(
		XRToolsPointerEvent.Type.PRESSED, null, win, world_pos, world_pos)


func _handle(handles: Node, handle_id: String) -> Node3D:
	for child in handles.get_children():
		if child.get_meta("handle_id", "") == handle_id:
			return child as Node3D
	return null


func _mesh(win: SWindow, part: String) -> QuadMesh:
	return (win.get_node(part + "/Screen") as MeshInstance3D).mesh as QuadMesh


func _shape(win: SWindow, part: String) -> BoxShape3D:
	return (win.get_node(part + "/StaticBody3D/CollisionShape3D") as CollisionShape3D).shape \
			as BoxShape3D


func _body(win: SWindow, part: String) -> StaticBody3D:
	return win.get_node(part + "/StaticBody3D") as StaticBody3D


func _viewport(win: SWindow, part: String) -> SubViewport:
	return win.get_node(part + "/Viewport") as SubViewport


func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		print("  ok   ", label)
	else:
		_failures += 1
		print("  FAIL ", label, "" if detail.is_empty() else "  (got %s)" % detail)
