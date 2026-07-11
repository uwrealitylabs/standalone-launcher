extends SceneTree
# TEMP verification script for z-order hardening. Run:
#   godot --headless -s res://tests/zorder_test.gd


const GRID_EPS := 0.0001
var _failures := 0


func _check(label: String, cond: bool) -> void:
	if cond:
		print("PASS: " + label)
	else:
		_failures += 1
		print("FAIL: " + label)


func _on_grid(win: SWindow) -> bool:
	var expected := SWindow.LAYER_ORIGIN_Z + win.z_order * SWindow.Z_STEP
	return absf(win.position.z - expected) < GRID_EPS


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

	# _ready created 2 windows; add a third
	var w3 := wm.create_window(Vector3(0.0, 1.2, -2.0))
	await process_frame
	var wins := wm.windows_list

	_check("3 windows exist", wins.size() == 3)
	_check("all on grid after spawn", wins.all(_on_grid))
	_check("distinct depths after spawn", _distinct_depths(wm))
	_check("last spawned is focused", wm.get_focused_window() == w3)

	# --- drag w3, change stack mid-drag (the old drift repro) ---
	var a: SWindow = wins[0]
	w3.start_drag(w3.global_position)
	w3.update_drag(w3.global_position + Vector3(0.4, 0.2, 0.0))
	for i in 5:
		await process_frame
	a.focus()  # mid-drag focus change -> recalculate z order
	for i in 5:
		await process_frame
	w3.stop_drag()
	await process_frame
	_check("all on grid after mid-drag focus change", wins.all(_on_grid))
	_check("distinct depths after mid-drag focus change", _distinct_depths(wm))
	var before := wm.windows_list.duplicate()
	a.focus()
	_check("refocusing focused window is a no-op reorder",
		wm.windows_list == before)

	# --- resize w3, change stack mid-resize (the old shared-z repro) ---
	w3.start_resize("R", w3.global_position + Vector3(0.75, 0, 0))
	w3.update_resize(w3.global_position + Vector3(0.9, 0, 0))
	a.focus()
	w3.update_resize(w3.global_position + Vector3(1.0, 0, 0))
	w3.stop_resize()
	await process_frame
	_check("all on grid after mid-resize focus change", wins.all(_on_grid))
	_check("distinct depths after mid-resize focus change", _distinct_depths(wm))

	# --- close focused window mid-drag of another ---
	a.focus()  # ensure the closed window is not the dragged one
	var focused := wm.get_focused_window()
	w3.start_drag(w3.global_position)
	focused.close()
	await process_frame
	await process_frame
	w3.stop_drag()
	await process_frame
	_check("2 windows remain after close", wm.windows_list.size() == 2)
	_check("all on grid after close mid-drag",
		wm.windows_list.all(_on_grid))
	_check("distinct depths after close mid-drag", _distinct_depths(wm))
	_check("focus promoted to new frontmost",
		wm.get_focused_window() == wm.windows_list[-1])

	print("RESULT: %s" % ("ALL PASS" if _failures == 0 else "%d FAILURES" % _failures))
	quit(1 if _failures else 0)
