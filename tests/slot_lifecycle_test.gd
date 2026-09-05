extends SceneTree

## Verifies WindowManager's slot placement, focus, and lifecycle contract:
## windows fill fixed slots in a set order, focus is tracked separately from
## placement (it moves no window), and closing a window frees its slot and
## promotes focus by most-recent-use without disturbing the survivors.
##
## Run with:
##   godot --headless --xr-mode off --path . \
##       --script res://tests/slot_lifecycle_test.gd
##
## --xr-mode off is required: without it a modal OpenXR alert hangs the run.
##
## The "Viewport Texture must be set to use it" errors are expected with no
## display server, not failures.

const Report := preload("res://tests/support/report.gd")

const APP_MENU := "res://project/launch_service/application_menu.tscn"
const TERMINAL := "res://project/shell/terminal_ui.tscn"

var _report := Report.new()


## Content-scene resource path of `win`, or "null" when it carries none.
func _content_path(win: SWindow) -> String:
	return "null" if win.content == null else win.content.resource_path


func _initialize() -> void:
	var wm_scene: PackedScene = load("res://project/windowing/window_manager.tscn")
	var wm: WindowManager = wm_scene.instantiate()
	root.add_child(wm)
	await process_frame

	var LEFT := WindowManager.Slot.LEFT
	var CENTRE := WindowManager.Slot.CENTRE
	var RIGHT := WindowManager.Slot.RIGHT

	# --- startup placement ---------------------------------------------------
	# _ready opens the menu into CENTRE, then the terminal into RIGHT; the
	# terminal, opening last, is the focused one. LEFT stays empty.
	_report.section("startup")
	var menu: SWindow = wm.slots[CENTRE]
	var term: SWindow = wm.slots[RIGHT]
	_report.check("startup opens exactly two windows", wm.open_windows.size() == 2,
			str(wm.open_windows.size()))
	_report.check("the menu takes CENTRE",
			menu != null and _content_path(menu) == APP_MENU, _content_path(menu))
	_report.check("the terminal takes RIGHT",
			term != null and _content_path(term) == TERMINAL, _content_path(term))
	_report.check("LEFT starts empty", wm.slots[LEFT] == null)
	_report.check("the last-opened window (terminal) is focused",
			wm.focused_window == term)

	# Content is installed before the initial focus, so the content scene really
	# instantiated and receives its first focus callback.
	_report.check("the menu content instantiated before focus",
			menu.content_3d.get_scene_instance() != null)

	# --- opening into the last slot ------------------------------------------
	_report.section("open into the remaining slot")
	var w3 := wm.create_window()
	await process_frame
	_report.check("the third window takes LEFT", wm.slots[LEFT] == w3)
	_report.check("opening focuses the new window", wm.focused_window == w3)
	_report.check("all three windows are open", wm.open_windows.size() == 3,
			str(wm.open_windows.size()))

	# --- opening when full is refused ----------------------------------------
	# A fourth request must change nothing: no window, no slot churn, no focus or
	# order change.
	_report.section("open when every slot is full")
	var slots_before := wm.slots.duplicate()
	var open_before := wm.open_windows.duplicate()
	var focus_before := wm.focused_window
	var overflow := wm.create_window()
	await process_frame
	_report.check("a fourth open returns null", overflow == null)
	_report.check("slots are untouched", wm.slots == slots_before)
	_report.check("the open list is untouched", wm.open_windows == open_before)
	_report.check("focus is untouched", wm.focused_window == focus_before)

	# --- focus moves nothing but input --------------------------------------
	# Focusing an already-open window must not move it, reorder the open list, or
	# resize it; it only changes which window is focused.
	_report.section("focus changes placement nothing")
	var xf_before := {menu: menu.transform, term: term.transform, w3: w3.transform}
	var sizes_before := {menu: menu.content_size, term: term.content_size,
			w3: w3.content_size}
	var order_before := wm.open_windows.duplicate()
	wm.focus(menu)
	await process_frame
	_report.check("focus follows the request", wm.focused_window == menu)
	_report.check("no window moved",
			menu.transform.is_equal_approx(xf_before[menu])
					and term.transform.is_equal_approx(xf_before[term])
					and w3.transform.is_equal_approx(xf_before[w3]))
	_report.check("slot occupancy is unchanged",
			wm.slots[CENTRE] == menu and wm.slots[RIGHT] == term and wm.slots[LEFT] == w3)
	_report.check("the open list order is unchanged", wm.open_windows == order_before)
	_report.check("no window was resized",
			menu.content_size == sizes_before[menu]
					and term.content_size == sizes_before[term]
					and w3.content_size == sizes_before[w3])

	# --- repeated focus is idempotent ----------------------------------------
	# Re-focusing the focused window must not duplicate it in the MRU history.
	_report.section("repeated focus")
	var history_before := wm.focus_history.duplicate()
	wm.focus(menu)
	_report.check("re-focusing does not touch the MRU history",
			wm.focus_history == history_before)
	_report.check("the focused window appears once in the history",
			wm.focus_history.count(menu) == 1)

	# --- closing the focused window promotes the MRU survivor ----------------
	# History is [menu, w3, term] (menu most recent). Closing menu must promote
	# w3, the most recent survivor, not the terminal.
	_report.section("close the focused window")
	_report.check("the terminal is not the most recent survivor",
			wm.focus_history[0] == menu and wm.focus_history[1] == w3)
	menu.close()
	await process_frame
	_report.check("the closed window left the open list", menu not in wm.open_windows)
	_report.check("CENTRE is now empty", wm.slots[CENTRE] == null)
	_report.check("focus promoted to the MRU survivor", wm.focused_window == w3)
	# Survivors are never relocated to fill the freed slot.
	_report.check("the survivors did not move",
			term.transform.is_equal_approx(xf_before[term])
					and w3.transform.is_equal_approx(xf_before[w3]))
	_report.check("RIGHT and LEFT still hold their windows",
			wm.slots[RIGHT] == term and wm.slots[LEFT] == w3)

	# --- closing a non-focused window leaves focus alone ---------------------
	_report.section("close a non-focused window")
	term.close()
	await process_frame
	_report.check("closing an unfocused window leaves focus put", wm.focused_window == w3)
	_report.check("its slot is freed", wm.slots[RIGHT] == null)
	_report.check("the last window keeps its slot and pose",
			wm.slots[LEFT] == w3 and w3.transform.is_equal_approx(xf_before[w3]))

	_report.finish(self)
