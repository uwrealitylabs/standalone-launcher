extends SceneTree

## Verifies that SWindow._apply_size keeps every size-dependent part in sync.
##
## Runs the window in a live tree so _ready and the resize gesture path both
## execute.
##
## Run with:
##   godot --headless --xr-mode off --path . \
##       --script res://tests/window_size_check.gd
##
## --xr-mode off is required: without it a modal OpenXR alert hangs the run.
##
## The "Viewport Texture must be set to use it" errors are expected with no
## display server, not failures.

const Report := preload("res://tests/support/report.gd")
const Fixtures := preload("res://tests/support/window_fixtures.gd")

const WINDOW_SCENE := "res://project/windowing/window.tscn"
const EPS := 0.001
const THROTTLED := XRToolsViewport2DIn3D.UpdateMode.UPDATE_THROTTLED

var _report := Report.new()


## The pixel density window.tscn authors `part` ("Header" or "Content") at,
## taken from a copy of the scene that never entered the tree so SWindow has not
## had a chance to overwrite it.
func _authored_ppu(part: String) -> float:
	var pristine: Node3D = load(WINDOW_SCENE).instantiate()
	var surface: Node3D = pristine.get_node(part)
	var ppu: float = surface.viewport_size.x / surface.screen_size.x
	pristine.free()
	return ppu


func _initialize() -> void:
	var win: SWindow = load(WINDOW_SCENE).instantiate()
	root.add_child(win)
	await process_frame

	_report.section("seeded from scene")
	_report.check("content_size seeded from content screen_size",
			win.content_size.is_equal_approx(Vector2(1.5, 0.75)), str(win.content_size))
	# SWindow declares both densities at 150.0 and overwrites them in _ready, so
	# a window that failed to seed would report that default rather than these.
	_report.near("PIXELS_PER_UNIT seeded from scene", win.PIXELS_PER_UNIT,
			_authored_ppu("Content"), 0.1)
	_report.near("HEADER_PIXELS_PER_UNIT seeded from scene", win.HEADER_PIXELS_PER_UNIT,
			_authored_ppu("Header"), 0.1)
	_report.check("both surfaces rest on the scene's throttled cadence",
			win.content_3d.update_mode == THROTTLED and win.header_3d.update_mode == THROTTLED,
			"%s / %s" % [win.content_3d.update_mode, win.header_3d.update_mode])
	_check_invariant(win)

	# --- live phase: screens track every frame, resolution waits for the clock ---
	var before_content_res: Vector2 = win.content_3d.viewport_size
	var before_header_res: Vector2 = win.header_3d.viewport_size
	# Held fixed for the whole gesture: the window itself slides as it resizes, so
	# re-reading global_position each frame would compound the drag
	var origin: Vector3 = win.global_position
	win.start_resize("R", Fixtures.press_at(win, origin))
	win.update_resize(origin + Vector3(0.4, 0, 0))
	win._process(0.001)

	# Fixed-centre resize doubles the pointer displacement: a 0.4 m grab pulls the
	# grabbed edge out by 0.4 and the opposite edge out by 0.4, so 1.5 -> 2.3.
	_report.section("mid-gesture, inside the commit interval")
	_report.check("content grew to 2.3 wide", absf(win.content_size.x - 2.3) < EPS,
			str(win.content_size))
	_check_screens_agree(win)
	_report.check("gesture leaves the content redraw cadence alone",
			win.content_3d.update_mode == THROTTLED, str(win.content_3d.update_mode))
	_report.check("gesture leaves the header redraw cadence alone",
			win.header_3d.update_mode == THROTTLED, str(win.header_3d.update_mode))
	_report.check("content resolution waits for the interval",
			win.content_3d.viewport_size.is_equal_approx(before_content_res),
			str(win.content_3d.viewport_size))
	_report.check("header resolution waits for the interval",
			win.header_3d.viewport_size.is_equal_approx(before_header_res),
			str(win.header_3d.viewport_size))

	# --- pointer stops moving but never releases: the clock must still catch up ---
	# Standing in for a target that has already been drawn, which is the state a
	# reallocation would otherwise leave blank until the addon's own clock fires
	var cvp: SubViewport = Fixtures.viewport(win, "Content")
	var hvp: SubViewport = Fixtures.viewport(win, "Header")
	cvp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	hvp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	win._process(SWindow.MIN_COMMIT_INTERVAL)

	_report.section("held still past the interval")
	_report.check("commit re-arms the content redraw",
			cvp.render_target_update_mode == SubViewport.UPDATE_ONCE,
			str(cvp.render_target_update_mode))
	_report.check("commit re-arms the header redraw",
			hvp.render_target_update_mode == SubViewport.UPDATE_ONCE,
			str(hvp.render_target_update_mode))
	_report.check("content resolution caught up without a release",
			not win.content_3d.viewport_size.is_equal_approx(before_content_res),
			str(win.content_3d.viewport_size))
	_report.check("header resolution caught up without a release",
			not win.header_3d.viewport_size.is_equal_approx(before_header_res),
			str(win.header_3d.viewport_size))
	_check_resolutions_agree(win)
	_report.check("no stretch left after a commit", _stretch(win) < EPS, "%.4f" % _stretch(win))

	# --- a nudge below the tolerance must not earn a reallocation ---
	var settled_res: Vector2 = win.content_3d.viewport_size
	cvp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	win.update_resize(origin + Vector3(0.41, 0, 0))
	win._process(1.0)

	_report.section("sub-tolerance nudge")
	_report.check("a sub-tolerance nudge does not earn a reallocation",
			win.content_3d.viewport_size.is_equal_approx(settled_res),
			str(win.content_3d.viewport_size))
	_report.check("a skipped commit does not re-arm the redraw",
			cvp.render_target_update_mode == SubViewport.UPDATE_DISABLED,
			str(cvp.render_target_update_mode))

	# --- release: everything settles exactly, whatever the throttle last did ---
	win.stop_resize()
	await process_frame

	_report.section("after release")
	_report.check("content resolution updated",
			not win.content_3d.viewport_size.is_equal_approx(before_content_res),
			str(win.content_3d.viewport_size))
	_check_invariant(win)

	# --- slow drag: the interval never binds, so the stretch gate governs ---
	_report.section("slow drag: stretch gate governs")
	var slow := _drag(win, -0.3, 3.0, 270)
	print("       worst stretch %.2f%%, %d commit(s) over 270 frames"
			% [slow.stretch * 100.0, slow.commits])
	_report.check("stretch stays within tolerance",
			slow.stretch <= SWindow.MAX_STRETCH + 0.005, "%.4f" % slow.stretch)
	_report.check("gate still allows some commits", slow.commits > 0, "%d" % slow.commits)
	_check_invariant(win)

	# --- fast drag: the stretch gate saturates, so the interval caps the cost ---
	_report.section("fast drag: interval gate governs")
	var fast := _drag(win, 1.3, 0.5, 45)
	var ceiling := int(ceil(0.5 / SWindow.MIN_COMMIT_INTERVAL)) + 1
	print("       worst stretch %.2f%%, %d commit(s) over 45 frames"
			% [fast.stretch * 100.0, fast.commits])
	_report.check("commits stay under the rate ceiling", fast.commits <= ceiling,
			"%d commits, ceiling %d" % [fast.commits, ceiling])
	_check_invariant(win)

	# --- clamping ---
	win.start_resize("R", Fixtures.press_at(win, win.global_position + Vector3(0.95, 0, 0)))
	win.update_resize(win.global_position + Vector3(9.0, 0, 0))
	win.stop_resize()
	await process_frame

	_report.section("clamped to MAX_CONTENT_SIZE")
	_report.near("content width clamped", win.content_size.x, SWindow.MAX_CONTENT_SIZE.x, EPS)
	_check_invariant(win)

	# --- each handle keeps the centre fixed and changes only its dimensions ---
	# Re-seeded before each gesture (inside the helper) so every drag stays clear
	# of the clamps, which would cap the size change and hide a wrong delta.
	_report.section("fixed centre, doubled deltas")
	_check_fixed_centre(win, "R", Vector3(0.3, 0, 0), 0.6, 0.0)
	_check_fixed_centre(win, "L", Vector3(-0.3, 0, 0), 0.6, 0.0)
	_check_fixed_centre(win, "B", Vector3(0, -0.2, 0), 0.0, 0.4)
	_check_fixed_centre(win, "BR", Vector3(0.3, -0.2, 0), 0.6, 0.4)
	_check_fixed_centre(win, "BL", Vector3(-0.3, -0.2, 0), 0.6, 0.4)
	_check_invariant(win)

	# --- the same local displacement resizes the same at any yaw ---
	_report.section("rotation-safe")
	var yaw_0 := _width_change_for_yaw(win, 0.0)
	_report.near("yaw 0 doubles the 0.3 displacement", yaw_0, 0.6, EPS)
	_report.near("yaw +theta matches yaw 0", _width_change_for_yaw(win, deg_to_rad(30)),
			yaw_0, EPS)
	_report.near("yaw -theta matches yaw 0", _width_change_for_yaw(win, deg_to_rad(-30)),
			yaw_0, EPS)
	win.rotation = Vector3.ZERO
	win._apply_size(Vector2(1.5, 0.75))
	_check_invariant(win)

	_report.finish(self)


## Full contract: screens, resolutions, header placement, resource separation.
func _check_invariant(win: SWindow) -> void:
	_check_screens_agree(win)
	_check_resolutions_agree(win)

	var expected_y: float = (win.content_size.y + SWindow.HEADER_HEIGHT) / 2.0
	_report.check("header sits above content", absf(win.header_3d.position.y - expected_y) < EPS,
			"%.5f vs %.5f" % [win.header_3d.position.y, expected_y])

	var header_bottom: float = win.header_3d.position.y - SWindow.HEADER_HEIGHT / 2.0
	var content_top: float = win.content_3d.position.y + win.content_size.y / 2.0
	_report.check("no seam between header and content", absf(header_bottom - content_top) < EPS,
			"%.5f vs %.5f" % [header_bottom, content_top])

	_report.check("header and content own separate meshes",
			Fixtures.mesh(win, "Header").get_instance_id()
					!= Fixtures.mesh(win, "Content").get_instance_id())
	_report.check("header and content own separate shapes",
			Fixtures.shape(win, "Header").get_instance_id()
					!= Fixtures.shape(win, "Content").get_instance_id())

	var handles := win.get_node_or_null("ResizeHandles")
	_report.check("resize handles exist", handles != null and handles.get_child_count() == 5,
			"%d handle(s)" % (handles.get_child_count() if handles else -1))
	var right := Fixtures.handle(win, "R")
	_report.check("R handle on the content edge",
			right != null and absf(right.position.x - win.content_size.x / 2.0) < EPS,
			str(right.position) if right else "missing")


## Asserts each surface's mesh, collision shape and world-to-viewport
## translator all describe the same physical screen.
func _check_screens_agree(win: SWindow) -> void:
	var content := win.content_size
	var header := Vector2(win.content_size.x, SWindow.HEADER_HEIGHT)

	_report.check("content mesh == content_size",
			Fixtures.mesh(win, "Content").size.is_equal_approx(content),
			str(Fixtures.mesh(win, "Content").size))
	_report.check("content shape == content_size",
			Fixtures.shape(win, "Content").size.is_equal_approx(
					Vector3(content.x, content.y, SWindow.SCREEN_DEPTH)),
			str(Fixtures.shape(win, "Content").size))
	_report.check("content screen_size == content_size",
			win.content_3d.screen_size.is_equal_approx(content),
			str(win.content_3d.screen_size))
	_report.check("content body translator == content_size",
			Fixtures.body(win, "Content").screen_size.is_equal_approx(content),
			str(Fixtures.body(win, "Content").screen_size))

	_report.check("header mesh == header size",
			Fixtures.mesh(win, "Header").size.is_equal_approx(header),
			str(Fixtures.mesh(win, "Header").size))
	_report.check("header shape == header size",
			Fixtures.shape(win, "Header").size.is_equal_approx(
					Vector3(header.x, header.y, SWindow.SCREEN_DEPTH)),
			str(Fixtures.shape(win, "Header").size))
	_report.check("header screen_size == header size",
			win.header_3d.screen_size.is_equal_approx(header),
			str(win.header_3d.screen_size))
	_report.check("header body translator == header size",
			Fixtures.body(win, "Header").screen_size.is_equal_approx(header),
			str(Fixtures.body(win, "Header").screen_size))


## Asserts each surface's render resolution matches its screen at the window's
## pixel density, and that the SubViewport and the body's translator agree.
func _check_resolutions_agree(win: SWindow) -> void:
	var content := win.content_size
	var header := Vector2(win.content_size.x, SWindow.HEADER_HEIGHT)
	var want_content := _expected_res(content, win.PIXELS_PER_UNIT)
	var want_header := _expected_res(header, win.HEADER_PIXELS_PER_UNIT)

	_report.check("content viewport_size == size x ppu",
			win.content_3d.viewport_size.is_equal_approx(want_content),
			"%s vs %s" % [win.content_3d.viewport_size, want_content])
	_report.check("content SubViewport matches",
			Fixtures.viewport(win, "Content").size == Vector2i(want_content),
			str(Fixtures.viewport(win, "Content").size))
	_report.check("content body resolution matches",
			Fixtures.body(win, "Content").viewport_size.is_equal_approx(want_content),
			str(Fixtures.body(win, "Content").viewport_size))

	_report.check("header viewport_size == size x ppu",
			win.header_3d.viewport_size.is_equal_approx(want_header),
			"%s vs %s" % [win.header_3d.viewport_size, want_header])
	_report.check("header SubViewport matches",
			Fixtures.viewport(win, "Header").size == Vector2i(want_header),
			str(Fixtures.viewport(win, "Header").size))
	_report.check("header body resolution matches",
			Fixtures.body(win, "Header").viewport_size.is_equal_approx(want_header),
			str(Fixtures.body(win, "Header").viewport_size))

	_report.check("content aspect matches screen aspect",
			absf(want_content.x / want_content.y - content.x / content.y) < 0.01,
			"%.4f vs %.4f" % [want_content.x / want_content.y, content.x / content.y])


## Drives a whole resize gesture that changes the content width by `grow` world
## units over `seconds` of simulated time, ticking the throttle clock by hand so
## the result does not depend on the host's frame rate. Reports the worst stretch
## seen and how many times the render target was reallocated.
func _drag(win: SWindow, grow: float, seconds: float, frames: int) -> Dictionary:
	var origin: Vector3 = win.global_position
	win.start_resize("R", Fixtures.press_at(win, origin))
	var dt := seconds / float(frames)
	var last_res: Vector2 = win.content_3d.viewport_size
	var commits := 0
	var worst := 0.0
	for i in frames:
		win.update_resize(origin + Vector3(grow * float(i + 1) / frames, 0, 0))
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


## Runs one whole resize gesture on `handle`, dragging the grab point by `move`,
## then asserts the content centre held still and each dimension changed by the
## expected amount. Re-seeds to 1.5 x 0.75 first so the gesture stays clear of
## the clamps, which would cap the delta and hide a wrong result.
func _check_fixed_centre(win: SWindow, handle: String, move: Vector3,
		expect_dw: float, expect_dh: float) -> void:
	win.rotation = Vector3.ZERO
	win._apply_size(Vector2(1.5, 0.75))
	var centre_before: Vector3 = win.content_3d.global_position
	var size_before: Vector2 = win.content_size

	var origin: Vector3 = win.global_position
	win.start_resize(handle, Fixtures.press_at(win, origin))
	win.update_resize(origin + move)
	win.stop_resize()

	var centre_after: Vector3 = win.content_3d.global_position
	_report.check("%s keeps the content centre fixed" % handle,
			centre_after.is_equal_approx(centre_before),
			"%s -> %s" % [centre_before, centre_after])
	_report.near("%s widens by %.1f" % [handle, expect_dw],
			win.content_size.x - size_before.x, expect_dw, EPS)
	_report.near("%s grows tall by %.1f" % [handle, expect_dh],
			win.content_size.y - size_before.y, expect_dh, EPS)


## Yaws the window by `yaw` radians, then drives an R-handle gesture whose grab
## point is pushed 0.3 m along the window's own local +X. Returns the resulting
## width change, which a rotation-safe resize must leave at 0.6 regardless of yaw.
func _width_change_for_yaw(win: SWindow, yaw: float) -> float:
	win.rotation = Vector3(0, yaw, 0)
	win._apply_size(Vector2(1.5, 0.75))
	var width_before: float = win.content_size.x

	var origin: Vector3 = win.global_position
	var local_x: Vector3 = win.global_transform.basis.x.normalized()
	win.start_resize("R", Fixtures.press_at(win, origin))
	win.update_resize(origin + local_x * 0.3)
	win.stop_resize()
	return win.content_size.x - width_before
