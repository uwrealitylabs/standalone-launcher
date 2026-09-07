extends SceneTree

## Verifies fixed-centre resize: the content centre stays put and both edges
## grow symmetrically, even when the pointer overshoots the numeric clamp in a
## single frame.
##
## A resize never moves the window origin. Past a clamp the pointer keeps moving
## while the size does not, so a later frame that comes back inside the range
## must track the pointer again from the frozen baseline.
##
## Run with:
##   godot --headless --xr-mode off --path . \
##       --script res://tests/resize_clamp_test.gd
##
## --xr-mode off is required: without it a modal OpenXR alert hangs the run.
##
## The "Viewport Texture must be set to use it" errors are expected with no
## display server, not failures.

const Report := preload("res://tests/support/report.gd")
const Fixtures := preload("res://tests/support/window_fixtures.gd")

# Clears any clamp in a single frame; a small step would land near the limit and
# pass whether or not the clamp is applied correctly.
const BIG := 9.0
const EPS := 0.0001

var _report := Report.new()
var _expected_centre := Vector3.ZERO


## True when the two widest open windows satisfy beta_1 + beta_2 + g <= theta,
## the permutation-safe invariant every managed size change must preserve.
func _two_widest_ok(wm: WindowManager) -> bool:
	var betas: Array[float] = []
	for w in wm.open_windows:
		betas.append(wm.beta_of_width(w.content_size.x))
	betas.sort()
	betas.reverse()
	if betas.size() < 2:
		return true
	return betas[0] + betas[1] + wm.gutter_angle <= wm.slot_angle + EPS


## World-space content centre of `win`.
func _centre(win: SWindow) -> Vector3:
	return win.content_3d.global_position


## The world displacement of a `local` offset in `win`'s own frame. Slots are
## yawed, so a gesture expressed in window-local axes must be rotated into world
## space before it is fed to the pointer.
func _world(win: SWindow, local: Vector3) -> Vector3:
	return win.global_transform.basis * local


## Runs one resize gesture on a fresh window: grabs `handle` at the window
## origin, then jumps the pointer by `travel` (given in the window's local frame)
## in a single MOVED frame. Returns the window, left mid-gesture for the caller
## to inspect and close.
func _resize(wm: WindowManager, handle: String, travel: Vector3) -> SWindow:
	var win := wm.create_window()
	var origin: Vector3 = win.global_position
	win.start_resize(handle, Fixtures.press_at(win, origin))
	win.update_resize(origin + _world(win, travel))
	return win


func _centre_holds(win: SWindow, label: String) -> void:
	_report.check("%s keeps the content centre fixed" % label,
			_centre(win).is_equal_approx(_expected_centre), str(_centre(win)))


func _initialize() -> void:
	var wm_scene: PackedScene = load("res://project/windowing/window_manager.tscn")
	var wm: WindowManager = wm_scene.instantiate()
	root.add_child(wm)
	await process_frame

	# Every test window spawns into the same slot (startup fills CENTRE and RIGHT,
	# so each temporary window lands in LEFT), giving one fixed content centre a
	# correct resize must preserve.
	var probe := wm.create_window()
	await process_frame
	var s0: Vector2 = probe.content_size
	_expected_centre = _centre(probe)
	probe.close()
	await process_frame

	_report.section("shrink past the minimum")
	var w := _resize(wm, "R", Vector3(-BIG, 0, 0))
	_report.near("R: width clamped to min", w.content_size.x, SWindow.MIN_CONTENT_SIZE.x)
	_centre_holds(w, "R")
	w.close()
	await process_frame

	w = _resize(wm, "B", Vector3(0, BIG, 0))
	_report.near("B: height clamped to min", w.content_size.y, SWindow.MIN_CONTENT_SIZE.y)
	_centre_holds(w, "B")
	w.close()
	await process_frame

	# Width now tops out at the permutation-safe angular cap, which is tighter than
	# the numeric max for a window beside the two default startup windows.
	_report.section("grow past the maximum")
	w = _resize(wm, "R", Vector3(BIG, 0, 0))
	_report.near("R: width clamped to the angular cap", w.content_size.x,
			wm.max_content_width_for(w))
	_report.check("the cap is tighter than the numeric max here",
			w.content_size.x < SWindow.MAX_CONTENT_SIZE.x - EPS, str(w.content_size.x))
	_centre_holds(w, "R")
	_report.check("two-widest invariant holds after growing", _two_widest_ok(wm))
	w.close()
	await process_frame

	# A corner drives both axes, so clamping one must leave the other free to keep
	# tracking the pointer. BR: dw = +2dx, dh = -2dy.
	_report.section("one axis clamped, the other still tracking")
	w = _resize(wm, "BR", Vector3(BIG, -0.1, 0))
	_report.near("BR: width clamped to the angular cap", w.content_size.x,
			wm.max_content_width_for(w))
	_report.near("BR: height tracks the pointer", w.content_size.y, s0.y + 0.2)
	_centre_holds(w, "BR")
	w.close()
	await process_frame

	# The cap follows the formula and binds programmatic resize() too, not just the
	# gesture path.
	_report.section("angular width cap")
	var cw := wm.create_window()
	await process_frame
	var expected_cap := wm.width_of_beta(wm.slot_angle - wm.gutter_angle - wm.default_half_width)
	_report.near("cap == theta - g - beta_default", wm.max_content_width_for(cw), expected_cap)
	cw.resize(Vector2(BIG, wm.default_height))
	_report.near("resize() cannot exceed the angular cap", cw.content_size.x, expected_cap)
	_report.check("two-widest invariant holds after a programmatic grow",
			_two_widest_ok(wm))
	cw.close()
	await process_frame

	# The baseline is frozen at grab time, so a frame spent clamped must leave no
	# residue in the frames that follow it.
	_report.section("recovering from a clamped frame")
	w = _resize(wm, "R", Vector3(BIG, 0, 0))
	var origin := w.global_position
	w.update_resize(origin + _world(w, Vector3(0.1, 0, 0)))
	_report.near("width follows the pointer again", w.content_size.x, s0.x + 0.2)
	_centre_holds(w, "recovered")
	w.stop_resize()
	await process_frame
	_report.near("width unchanged after release", w.content_size.x, s0.x + 0.2)
	_centre_holds(w, "after release")
	w.close()
	await process_frame

	# Only one window may resize at a time, and closing the active window must
	# release its ownership. Uses the two startup windows so two grabs are possible
	# (the three-slot limit leaves only one free slot for a temporary window).
	_report.section("exclusive resize ownership")
	var m: SWindow = wm.slots[WindowManager.Slot.CENTRE]
	var t: SWindow = wm.slots[WindowManager.Slot.RIGHT]
	m.start_resize("R", Fixtures.press_at(m, m.global_position))
	_report.check("the first gesture takes ownership", wm.resizing_window == m)
	t.start_resize("R", Fixtures.press_at(t, t.global_position))
	_report.check("a second simultaneous resize is refused", wm.resizing_window == m)
	_report.check("the refused window did not start resizing", not t._resizing)
	m.close()
	await process_frame
	_report.check("closing the active window clears ownership", wm.resizing_window == null)
	t.start_resize("R", Fixtures.press_at(t, t.global_position))
	_report.check("ownership is grantable again after release", wm.resizing_window == t)
	t.stop_resize()
	await process_frame

	_report.finish(self)
