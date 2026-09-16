extends SceneTree

## Guards the two-click close bug: the app menu's close button must close the
## window on a single press+release even when the window starts unfocused.
##
## The menu once grabbed its search bar on every focus change. Clicking the close
## button of an unfocused menu focused the window first, and that grab pulled GUI
## focus into the Content viewport mid-press, so the Header's close button never
## latched and a second click was needed. With the grab removed the first click
## closes it, matching a plain window like the terminal.
##
## Run with:
##   godot --headless --xr-mode off --path . \
##       --script res://tests/close_button_focus_test.gd
##
## --xr-mode off is required: without it a modal OpenXR alert hangs the run.
##
## The "Viewport Texture must be set to use it" errors are expected with no
## display server, not failures.

const Report := preload("res://tests/support/report.gd")
const Fixtures := preload("res://tests/support/window_fixtures.gd")

const APPS := ["Alpha", "Bravo"]

var _report := Report.new()
var _fixture_dir := ""


## The app menu's window among the manager's windows, or null.
func _find_menu_window(wm: WindowManager) -> SWindow:
	for win in wm.open_windows:
		var inst = win.content_3d.get_scene_instance()
		if inst and inst.has_method("populate_apps"):
			return win
	return null


## World position of a control's centre on `part`'s viewport surface, inverting
## the body's viewport-to-screen mapping so a headless click can target it.
func _world_of_control(win: SWindow, part: String, ctrl: Control) -> Vector3:
	var body := Fixtures.body(win, part)
	var col: CollisionShape3D = body.get_node("CollisionShape3D")
	var screen_size: Vector2 = body.screen_size
	var viewport_size: Vector2 = body.viewport_size
	var vc := ctrl.get_global_rect().get_center()
	var local := Vector3(
		((vc.x / viewport_size.x) - 0.5) * screen_size.x,
		(0.5 - (vc.y / viewport_size.y)) * screen_size.y,
		0.0)
	return col.global_transform * local


## Presses and releases the close button of `win` in one gesture, as a hand
## pointer would, and returns whether the window closed.
func _click_close(win: SWindow) -> bool:
	var closed := {"v": false}
	win.closed.connect(func(): closed["v"] = true)
	var close_button: Button = win.header_3d.get_scene_instance().close_button
	var world := _world_of_control(win, "Header", close_button)
	var body := Fixtures.body(win, "Header")
	body.emit_signal("pointer_event",
			Fixtures.event_at(XRToolsPointerEvent.Type.PRESSED, body, world))
	await process_frame
	body.emit_signal("pointer_event",
			Fixtures.event_at(XRToolsPointerEvent.Type.RELEASED, body, world))
	await process_frame
	return closed["v"]


## Writes one .desktop file per name in APPS and points SHARE_DIR_ENV at the tree
## holding them. Must run before the manager is built, since the menu scans on
## _ready.
func _write_share_dir() -> void:
	_fixture_dir = OS.get_user_data_dir() + "/close_button_focus_test"
	for sub in ["applications", "icons", "pixmaps"]:
		DirAccess.make_dir_recursive_absolute(_fixture_dir + "/" + sub)
	for app_name in APPS:
		var path: String = "%s/applications/%s.desktop" % [_fixture_dir, app_name.to_lower()]
		var file := FileAccess.open(path, FileAccess.WRITE)
		file.store_string("[Desktop Entry]\nType=Application\nName=%s\nExec=/bin/true\n" % app_name)
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
	var menu_window := _find_menu_window(wm)
	_report.check("the app menu is one of the manager's windows", menu_window != null)
	if not menu_window:
		_report.check("cannot continue without the menu", false)
		_report.finish(self)
		return

	# The terminal is spawned last, so the menu is unfocused at startup: the exact
	# state in which the old focus-grab ate the first click.
	_report.check("the menu starts unfocused",
			wm.get_focused_window() != menu_window)

	_report.section("one click closes the unfocused menu")
	var closed: bool = await _click_close(menu_window)
	_report.check("a single click on the close button closes the menu", closed)
	_report.check("the window was actually freed", not is_instance_valid(menu_window))

	_remove_tree(_fixture_dir)
	OS.unset_environment(FileUtils.SHARE_DIR_ENV)
	_report.finish(self)
