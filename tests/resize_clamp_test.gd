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

const SPAWN := Vector3(0.0, 1.2, -2.0)
# Clears any clamp in a single frame; a small step would land near the limit and
# pass whether or not the clamp is applied correctly.
const BIG := 9.0

var _report := Report.new()
var _expected_centre := Vector3.ZERO


## World-space content centre of `win`.
func _centre(win: SWindow) -> Vector3:
	return win.content_3d.global_position


## Runs one resize gesture on a fresh window: grabs `handle` at the window
## origin, then jumps the pointer by `travel` in a single MOVED frame. Returns
## the window, left mid-gesture for the caller to inspect and close.
func _resize(wm: WindowManager, handle: String, travel: Vector3) -> SWindow:
	var win := wm.create_window(SPAWN)
	var origin: Vector3 = win.global_position
	win.start_resize(handle, Fixtures.press_at(win, origin))
	win.update_resize(origin + travel)
	return win


func _centre_holds(win: SWindow, label: String) -> void:
	_report.check("%s keeps the content centre fixed" % label,
			_centre(win).is_equal_approx(_expected_centre), str(_centre(win)))


func _initialize() -> void:
	var wm_scene: PackedScene = load("res://project/windowing/window_manager.tscn")
	var wm: WindowManager = wm_scene.instantiate()
	root.add_child(wm)
	await process_frame

	# Every test window spawns at the same pose, so its content centre is the
	# same fixed point a correct resize must preserve.
	var probe := wm.create_window(SPAWN)
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

	_report.section("grow past the maximum")
	w = _resize(wm, "R", Vector3(BIG, 0, 0))
	_report.near("R: width clamped to max", w.content_size.x, SWindow.MAX_CONTENT_SIZE.x)
	_centre_holds(w, "R")
	w.close()
	await process_frame

	# A corner drives both axes, so clamping one must leave the other free to keep
	# tracking the pointer. BR: dw = +2dx, dh = -2dy.
	_report.section("one axis clamped, the other still tracking")
	w = _resize(wm, "BR", Vector3(BIG, -0.1, 0))
	_report.near("BR: width clamped to max", w.content_size.x, SWindow.MAX_CONTENT_SIZE.x)
	_report.near("BR: height tracks the pointer", w.content_size.y, s0.y + 0.2)
	_centre_holds(w, "BR")
	w.close()
	await process_frame

	# The baseline is frozen at grab time, so a frame spent clamped must leave no
	# residue in the frames that follow it.
	_report.section("recovering from a clamped frame")
	w = _resize(wm, "R", Vector3(BIG, 0, 0))
	var origin := SPAWN
	w.update_resize(origin + Vector3(0.1, 0, 0))
	_report.near("width follows the pointer again", w.content_size.x, s0.x + 0.2)
	_centre_holds(w, "recovered")
	w.stop_resize()
	await process_frame
	_report.near("width unchanged after release", w.content_size.x, s0.x + 0.2)
	_centre_holds(w, "after release")
	w.close()
	await process_frame

	_report.finish(self)
