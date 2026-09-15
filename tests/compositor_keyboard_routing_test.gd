extends SceneTree

## Verifies Milestone 4: compositor_poc.gd routes keyboard input to its surface.
##
## The routing is thin GDScript over the already-proven translation boundary
## (tests/linux/translate_check.gd covers the boundary itself on arm64), so this
## suite drives the node with a fake compositor that only records what it was
## asked to do, and asserts the wiring:
##
##   - a mapped surface takes keyboard focus and the activated state, and both
##     clear on unmap or client-gone;
##   - real (USB) key events reach send_physical_key while focused;
##   - virtual-keyboard taps reach send_virtual_key while focused;
##   - nothing is forwarded once the surface is unfocused;
##   - attaching the same virtual keyboard twice still delivers each tap once.
##
## autostart is turned off so the node never brings up a real Wayland server --
## the suite then runs identically on every host, including the arm64 VM where
## the extension exists (compositor_visibility_check.gd has to skip there).
##
## Run with:
##   godot --headless --xr-mode off --path . \
##       --script res://tests/compositor_keyboard_routing_test.gd

const Report := preload("res://tests/support/report.gd")

const SCREEN_SCENE := "res://project/compositor/compositor_screen.tscn"
const KEYBOARD_SCENE := \
		"res://addons/godot-xr-tools/objects/keyboard/virtual_keyboard_2d.tscn"

const SURF := Vector2i(640, 480)


## Stands in for WaylandCompositor: records the input calls the router makes so
## the suite can assert the wiring without a real seat behind it. Extends Node
## because compositor_poc.gd holds its compositor in a Node-typed field.
class FakeCompositor:
	extends Node
	var focus_calls: Array[bool] = []
	var activated_calls: Array[bool] = []
	var physical: Array[InputEventKey] = []
	var virtual: Array[InputEventKey] = []

	func set_keyboard_focus(focused: bool) -> void:
		focus_calls.append(focused)

	func set_toplevel_activated(activated: bool) -> void:
		activated_calls.append(activated)

	func send_physical_key(event: InputEventKey) -> void:
		physical.append(event)

	func send_virtual_key(event: InputEventKey) -> void:
		virtual.append(event)

	# Called by compositor_poc.gd's teardown; harmless stubs so freeing the
	# screen with a fake attached stays clean.
	func get_stats() -> Dictionary:
		return {}

	func stop() -> void:
		pass


var _report := Report.new()


func _initialize() -> void:
	var scene: PackedScene = load(SCREEN_SCENE)
	if scene == null:
		_report.check("compositor_screen.tscn loads", false)
		_report.finish(self)
		return
	var screen := scene.instantiate() as MeshInstance3D
	# Set before the node enters the tree, so _ready sees it and brings nothing up.
	screen.autostart = false
	get_root().add_child(screen)
	await process_frame  # _ready runs and returns early

	var fake := FakeCompositor.new()
	screen.add_child(fake)
	screen._compositor = fake

	_check_focus_on_map(screen, fake)
	await _check_physical(screen, fake)
	var keyboard := await _check_virtual(screen, fake)
	_check_focus_clears(screen, fake)
	await _check_no_routing_unfocused(screen, fake, keyboard)
	await _check_attach_idempotent(screen, fake, keyboard)

	_report.finish(self)


func _check_focus_on_map(screen: MeshInstance3D, fake: FakeCompositor) -> void:
	_report.section("a mapped surface takes focus")
	screen._on_surface_mapped(SURF)
	_report.check("keyboard focus was set true",
			fake.focus_calls == [true], str(fake.focus_calls))
	_report.check("activated was set true",
			fake.activated_calls == [true],
			str(fake.activated_calls))


func _check_physical(screen: MeshInstance3D, fake: FakeCompositor) -> void:
	_report.section("physical keys route while focused")
	var down := _key(KEY_A, true)
	var up := _key(KEY_A, false)
	screen._unhandled_key_input(down)
	screen._unhandled_key_input(up)
	_report.check("both events forwarded to send_physical_key",
			fake.physical.size() == 2, str(fake.physical.size()))
	_report.check("the press keeps its keycode and pressed state",
			fake.physical.size() == 2 and fake.physical[0].keycode == KEY_A
			and fake.physical[0].pressed)
	_report.check("the release is forwarded as a release",
			fake.physical.size() == 2 and not fake.physical[1].pressed)


## Returns the keyboard it attaches, so later checks can drive it too.
func _check_virtual(screen: MeshInstance3D,
		fake: FakeCompositor) -> XRToolsVirtualKeyboard2D:
	_report.section("virtual keys route while focused")
	var keyboard := load(KEYBOARD_SCENE).instantiate() as XRToolsVirtualKeyboard2D
	get_root().add_child(keyboard)
	screen.attach_virtual_keyboard(keyboard)
	keyboard.on_key_pressed("C", 99, true)  # a shifted C
	await process_frame
	_report.check("the tap reached send_virtual_key", fake.virtual.size() == 1,
			str(fake.virtual.size()))
	_report.check("it carries the key and its shift flag",
			fake.virtual.size() == 1 and fake.virtual[0].keycode == KEY_C
			and fake.virtual[0].shift_pressed)
	return keyboard


func _check_focus_clears(screen: MeshInstance3D, fake: FakeCompositor) -> void:
	_report.section("unmap clears focus")
	screen._on_surface_unmapped()
	_report.check("keyboard focus was cleared",
			fake.focus_calls == [true, false],
			str(fake.focus_calls))
	_report.check("activated was cleared",
			fake.activated_calls == [true, false],
			str(fake.activated_calls))


func _check_no_routing_unfocused(screen: MeshInstance3D, fake: FakeCompositor,
		keyboard: XRToolsVirtualKeyboard2D) -> void:
	_report.section("nothing routes once unfocused")
	var physical_before := fake.physical.size()
	var virtual_before := fake.virtual.size()
	screen._unhandled_key_input(_key(KEY_B, true))
	keyboard.on_key_pressed("D", 100, false)
	await process_frame
	_report.check("no physical key was forwarded",
			fake.physical.size() == physical_before)
	_report.check("no virtual key was forwarded",
			fake.virtual.size() == virtual_before)


func _check_attach_idempotent(screen: MeshInstance3D, fake: FakeCompositor,
		keyboard: XRToolsVirtualKeyboard2D) -> void:
	_report.section("re-attaching the same keyboard does not double-route")
	screen._on_surface_mapped(SURF)  # focus again so taps are eligible
	screen.attach_virtual_keyboard(keyboard)  # second attach
	var virtual_before := fake.virtual.size()
	keyboard.on_key_pressed("E", 101, false)
	await process_frame
	_report.check("the tap was delivered exactly once",
			fake.virtual.size() == virtual_before + 1,
			str(fake.virtual.size() - virtual_before))


func _key(keycode: Key, pressed: bool) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = keycode
	event.keycode = keycode
	event.pressed = pressed
	return event
