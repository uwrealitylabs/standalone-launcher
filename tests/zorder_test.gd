extends SceneTree

## Verifies that WindowManager keeps the window stack coherent across changes
## that land in the middle of a drag or a resize.
##
## The contract under test: every window sits at LAYER_ORIGIN_Z + z_order *
## Z_STEP, no two share a depth, and the focused window is the frontmost one.
## Run with:
##   godot --headless --xr-mode off --path . --script res://tests/zorder_test.gd
##
## --xr-mode off is required: without it a modal OpenXR alert hangs the run.
##
## The "Viewport Texture must be set to use it" errors are expected with no
## display server, not failures.

const Report := preload("res://tests/support/report.gd")
const Fixtures := preload("res://tests/support/window_fixtures.gd")

const GRID_EPS := 0.0001
const APP_MENU := "res://project/launch_service/application_menu.tscn"

var _report := Report.new()


## True when `win` sits at exactly the depth its z_order calls for.
func _on_grid(win: SWindow) -> bool:
	var expected := SWindow.LAYER_ORIGIN_Z + win.z_order * SWindow.Z_STEP
	return absf(win.position.z - expected) < GRID_EPS


## True when no two windows in the stack share a depth.
func _distinct_depths(wm: WindowManager) -> bool:
	var seen := {}
	for w in wm.windows_list:
		var key := snappedf(w.position.z, 0.001)
		if seen.has(key):
			return false
		seen[key] = true
	return true


func _initialize() -> void:
	var wm_scene: PackedScene = load("res://project/windowing/window_manager.tscn")
	var wm: WindowManager = wm_scene.instantiate()
	root.add_child(wm)
	await process_frame

	_report.section("startup")
	_report.check("_ready spawns two windows", wm.windows_list.size() == 2,
			str(wm.windows_list.size()))
	# The app browser is the launcher's reason to exist, and nothing else in the
	# project instantiates it, so losing this line takes the feature out silently.
	var menu: SWindow = wm.windows_list[0]
	_report.check("the first window carries the app menu",
			menu.content != null and menu.content.resource_path == APP_MENU,
			"null" if menu.content == null else menu.content.resource_path)
	_report.check("the app menu really instantiated",
			menu.content_3d.get_scene_instance() != null)

	# WindowManager._ready spawns two windows; a third gives the stack a middle
	var w3 := wm.create_window(Vector3(0.0, 1.2, -2.0))
	await process_frame
	var wins := wm.windows_list

	_report.section("spawn")
	_report.check("3 windows exist", wins.size() == 3, str(wins.size()))
	_report.check("all on grid after spawn", wins.all(_on_grid))
	_report.check("distinct depths after spawn", _distinct_depths(wm))
	_report.check("last spawned is focused", wm.get_focused_window() == w3)

	# --- focus change mid-drag ---
	# Depth is owned by z_order alone, so reordering the stack while a drag is in
	# flight must move the dragged window in depth without taking it off the grid.
	var a: SWindow = wins[0]
	w3.start_drag(Fixtures.press_at(w3, w3.global_position))
	w3.update_drag(w3.global_position + Vector3(0.4, 0.2, 0.0))
	for i in 5:
		await process_frame
	a.focus()
	for i in 5:
		await process_frame
	w3.stop_drag()
	await process_frame

	_report.section("focus change mid-drag")
	_report.check("all on grid", wins.all(_on_grid))
	_report.check("distinct depths", _distinct_depths(wm))
	var before := wm.windows_list.duplicate()
	a.focus()
	_report.check("refocusing the focused window does not reorder",
			wm.windows_list == before)

	# --- focus change mid-resize ---
	# A resize slides the window as it runs, so pointer positions are anchored to
	# where the grab started; re-reading global_position mid-gesture would
	# compound the drag into the measurement.
	var w3_origin: Vector3 = w3.global_position
	w3.start_resize("R", Fixtures.press_at(w3, w3_origin + Vector3(0.75, 0, 0)))
	w3.update_resize(w3_origin + Vector3(0.9, 0, 0))
	a.focus()
	w3.update_resize(w3_origin + Vector3(1.0, 0, 0))
	w3.stop_resize()
	await process_frame

	_report.section("focus change mid-resize")
	_report.check("all on grid", wins.all(_on_grid))
	_report.check("distinct depths", _distinct_depths(wm))

	# --- closing the focused window while a different one is mid-drag ---
	# The drag has to start first: start_drag focuses the window it is given, so
	# focusing `a` afterwards is what leaves the closed window the focused one and
	# puts _on_window_closed down its promotion path.
	w3.start_drag(Fixtures.press_at(w3, w3.global_position))
	a.focus()
	_report.section("close the focused window mid-drag")
	_report.check("the window about to close is the focused one",
			wm.get_focused_window() == a)
	a.close()
	await process_frame
	await process_frame
	w3.stop_drag()
	await process_frame

	_report.check("2 windows remain", wm.windows_list.size() == 2,
			str(wm.windows_list.size()))
	_report.check("all on grid", wm.windows_list.all(_on_grid))
	_report.check("distinct depths", _distinct_depths(wm))
	_report.check("focus promoted to the new frontmost",
			wm.get_focused_window() == wm.windows_list[-1])

	_report.finish(self)
