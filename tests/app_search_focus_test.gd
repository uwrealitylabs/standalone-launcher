extends SceneTree

## Verifies that the app browser's search bar can be typed into.
##
## A LineEdit only receives keys while it holds focus inside its own SubViewport,
## and the launcher has no other focus owner, so the menu used to open deaf to the
## keyboard. This drives the real window manager rather than the menu alone,
## because the focus handoff being checked lives in SWindow.set_input_enabled.
## Run with:
##   godot --headless --xr-mode off --path . \
##       --script res://tests/app_search_focus_test.gd
##
## --xr-mode off is required: without an OpenXR runtime, initialization raises a
## modal alert that never gets dismissed and the run hangs.
##
## Adding window.tscn to a headless tree makes the engine print "Viewport
## Texture must be set to use it" — expected output with no display server, not
## a failure.

const Report := preload("res://tests/support/report.gd")

## Names chosen so that one keystroke tells the rows apart: only "Zulu" contains
## a "z", so a filtered list of one proves the text reached the filter. "Quiet"
## is written without an Exec, to press a row whose launch cannot get past the
## first guard in _on_app_button_pressed.
const APPS := ["Alpha", "Bravo", "Quiet", "Zulu"]
const NO_EXEC := "Quiet"

var _report := Report.new()
var _fixture_dir := ""


## The app menu's controller among the manager's windows, with its window.
func _find_menu(wm: WindowManager) -> Array:
	for win in wm.windows_list:
		var inst = win.content_3d.get_scene_instance()
		if inst and inst.has_method("populate_apps"):
			return [win, inst]
	return [null, null]


## The XRToolsVirtualKeyboard2D inside the WindowManager's keyboard, or null.
func _find_keyboard(wm: WindowManager) -> XRToolsVirtualKeyboard2D:
	for child in wm.get_children():
		if child is XRToolsViewport2DIn3D:
			var inst = child.get_scene_instance()
			if inst is XRToolsVirtualKeyboard2D:
				return inst
	return null


## Rows currently on screen. populate_apps clears with queue_free, so a row is
## still a child for the rest of the frame after it has logically gone.
func _rows(menu) -> Array:
	var out := []
	for row in menu.apps_list.get_children():
		if not row.is_queued_for_deletion():
			out.append(row)
	return out


## The click target overlaying each row.
func _row_buttons(menu) -> Array:
	var out := []
	for row in _rows(menu):
		for child in row.get_children():
			if child is Button:
				out.append(child)
	return out


## The button of the row showing `app_name`, found by the label rather than by
## position so the lookup does not depend on how the list is sorted.
func _button_for(menu, app_name: String) -> Button:
	for row in _rows(menu):
		if _has_label(row, app_name):
			for child in row.get_children():
				if child is Button:
					return child
	return null


func _has_label(node: Node, text: String) -> bool:
	if node is Label and node.text == text:
		return true
	for child in node.get_children():
		if _has_label(child, text):
			return true
	return false


## A physical key as the engine delivers it on the board, where OpenXR is active
## and SWindow therefore leaves content_3d processing input. The virtual keyboard
## cannot stand in here: it has no Tab among its keys.
func _press_physical(win: SWindow, keycode: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.physical_keycode = keycode
	event.pressed = true
	win.send_input(event)


## Writes one .desktop file per name in APPS and points SHARE_DIR_ENV at the
## tree holding them. Must run before the manager is built, since the menu scans
## on _ready.
func _write_share_dir() -> void:
	_fixture_dir = OS.get_user_data_dir() + "/app_search_focus_test"
	# icons/ and pixmaps/ exist but stay empty: the icon lookup is not what this
	# suite measures, and a walk over an absent directory is noise either way.
	for sub in ["applications", "icons", "pixmaps"]:
		DirAccess.make_dir_recursive_absolute(_fixture_dir + "/" + sub)
	for app_name in APPS:
		var path: String = "%s/applications/%s.desktop" % [_fixture_dir, app_name.to_lower()]
		var file := FileAccess.open(path, FileAccess.WRITE)
		var body := "[Desktop Entry]\nType=Application\nName=%s\n" % app_name
		if app_name != NO_EXEC:
			body += "Exec=/bin/true\n"
		file.store_string(body)
		file.close()
	OS.set_environment(FileUtils.SHARE_DIR_ENV, _fixture_dir)


func _remove_tree(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for sub in dir.get_directories():
		_remove_tree(path + "/" + sub)
	for f in dir.get_files():
		DirAccess.remove_absolute(path + "/" + f)
	DirAccess.remove_absolute(path)


func _initialize() -> void:
	_write_share_dir()

	var wm_scene: PackedScene = load("res://project/windowing/window_manager.tscn")
	var wm: WindowManager = wm_scene.instantiate()
	root.add_child(wm)
	await process_frame
	await process_frame

	_report.section("setup")
	var found := _find_menu(wm)
	var menu_window: SWindow = found[0]
	var menu = found[1]
	var kb := _find_keyboard(wm)
	_report.check("the app menu is one of the manager's windows", menu != null)
	_report.check("keyboard found under the window manager", kb != null)
	if not menu or not kb:
		_report.check("cannot continue without both", false)
		_report.finish(self)
		return

	_report.check("every fixture app has a row", _rows(menu).size() == APPS.size(),
			str(_rows(menu).size()))

	var terminal_window: SWindow = null
	for win in wm.windows_list:
		if win != menu_window:
			terminal_window = win
	_report.check("a second window exists to compare against", terminal_window != null)

	# The terminal is spawned last, so it is the focused window at startup. The
	# search bar still holds GUI focus, which is per-viewport and independent.
	_report.section("focus at startup")
	_report.check("the terminal starts as the focused window",
			wm.get_focused_window() != menu_window)
	_report.check("the search bar already holds focus in its own viewport",
			menu.search_bar.has_focus())

	_report.section("the menu takes focus")
	menu_window.focus()
	await process_frame
	_report.check("the menu is now the focused window",
			wm.get_focused_window() == menu_window)

	# Both of a window's viewports are gated, not just the content one: the
	# header shares the window's keyboard, so an ungated one would keep taking
	# physical keys for every window at once.
	_report.section("keyboard routing follows the focused window")
	_report.check("the focused window's content takes keys",
			menu_window.content_3d.input_keyboard)
	_report.check("the focused window's header takes keys",
			menu_window.header_3d.input_keyboard)
	_report.check("the unfocused window's content does not",
			not terminal_window.content_3d.input_keyboard)
	_report.check("the unfocused window's header does not",
			not terminal_window.header_3d.input_keyboard)
	# The header's gamepad flag is deliberately left as authored. It is off by
	# default and the scene does not override it, so gating it would turn it on.
	_report.check("the focused window's header still ignores the gamepad",
			not menu_window.header_3d.input_gamepad)

	# Rows must stay focusable. A hardware keyboard is a real input path on the
	# board -- OpenXR is active there, so SWindow leaves content_3d processing
	# input and physical keys reach the viewport -- and Tab is how it gets to a
	# row to launch it with Enter.
	_report.section("rows stay reachable from a hardware keyboard")
	var gui: Viewport = menu.get_viewport()
	_press_physical(menu_window, KEY_TAB)
	await process_frame
	var tabbed: Control = gui.gui_get_focus_owner()
	_report.check("Tab moves focus off the search bar", tabbed != menu.search_bar)
	_report.check("Tab lands on a row button",
			tabbed is Button and _row_buttons(menu).has(tabbed),
			str(tabbed))

	_report.section("pressing a row returns focus to the search bar")
	# The row without an Exec goes first: its press cannot get past the launch
	# guard, so focus coming back proves the re-grab runs ahead of that guard.
	var quiet := _button_for(menu, NO_EXEC)
	_report.check("the Exec-less row has a button", quiet != null)
	quiet.pressed.emit()
	await process_frame
	_report.check("a row that cannot launch still hands focus back",
			menu.search_bar.has_focus())

	var zulu := _button_for(menu, "Zulu")
	zulu.grab_focus()
	zulu.pressed.emit()
	await process_frame
	_report.check("a row that does launch hands focus back",
			menu.search_bar.has_focus())

	# Known gap in this design: focus is taken back on `pressed`, which a press
	# released off the row never emits. Pinned here so the behaviour is a
	# recorded trade-off rather than a surprise.
	_report.section("known gap: a press released off the row")
	zulu.grab_focus()
	await process_frame
	_report.check("focus stays on the row when no press completes",
			gui.gui_get_focus_owner() == zulu)
	menu.search_bar.grab_focus()

	_report.section("typing into the focused menu")
	kb.on_key_pressed("Z", 122, false)
	await process_frame
	_report.check("the search bar received the keystroke",
			menu.search_bar.text == "z", menu.search_bar.text)
	# Asserting the row count as well, so the check covers the filter running and
	# not merely the character landing in the field.
	_report.check("the list filtered down to the one matching app",
			_rows(menu).size() == 1, str(_rows(menu).size()))

	_report.section("keys do not reach an unfocused menu")
	terminal_window.focus()
	await process_frame
	kb.on_key_pressed("Q", 113, false)
	await process_frame
	_report.check("the search text is unchanged while the terminal is focused",
			menu.search_bar.text == "z", menu.search_bar.text)

	# Dropping GUI focus first is what makes this a test of the handoff: left
	# alone the search bar would still hold focus and the check would pass with
	# the notification removed.
	_report.section("focus returns with the window")
	menu.search_bar.release_focus()
	_report.check("the search bar starts this check without focus",
			not menu.search_bar.has_focus())
	menu_window.focus()
	await process_frame
	_report.check("re-focusing the window puts the caret back in the search bar",
			menu.search_bar.has_focus())

	_remove_tree(_fixture_dir)
	OS.unset_environment(FileUtils.SHARE_DIR_ENV)
	_report.finish(self)
