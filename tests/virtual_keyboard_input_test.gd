extends SceneTree

## Verifies that a virtual keypress reaches the focused window and nothing else.
##
## The keyboard reports keys by signal alone. Injecting them into the Input
## singleton instead would latch each one as held forever, because a virtual key
## carries no matching release, and anything polling Input — the XR simulator's
## WASD locomotion, any global input handler — would act on it. Run with:
##   godot --headless --xr-mode off --path . \
##       --script res://tests/virtual_keyboard_input_test.gd
##
## --xr-mode off is required: without an OpenXR runtime, initialization raises a
## modal alert that never gets dismissed and the run hangs.
##
## Adding window.tscn to a headless tree makes the engine print "Viewport
## Texture must be set to use it" — expected output with no display server, not
## a failure.

const Report := preload("res://tests/support/report.gd")

var _report := Report.new()


## The simulator's own WASD-to-thumbstick mapping, which reads the global
## held-key state directly and so answers whether a keypress left a trace there.
func _left_stick() -> Vector2:
	var sim := root.get_node_or_null("XrSimulator")
	if sim:
		return sim.vector_key_mapping(KEY_D, KEY_A, KEY_W, KEY_S)
	# The autoload may be absent under --script. The function reads only Input,
	# so a bare instance answers the same question.
	var script: GDScript = load("res://addons/xr-simulator/XRSimulator.gd")
	return script.new().vector_key_mapping(KEY_D, KEY_A, KEY_W, KEY_S)


## The XRToolsVirtualKeyboard2D inside the WindowManager's keyboard, or null.
func _find_keyboard(wm: WindowManager) -> XRToolsVirtualKeyboard2D:
	for child in wm.get_children():
		if child is XRToolsViewport2DIn3D:
			var inst = child.get_scene_instance()
			if inst is XRToolsVirtualKeyboard2D:
				return inst
	return null


func _initialize() -> void:
	var wm_scene: PackedScene = load("res://project/windowing/window_manager.tscn")
	var wm: WindowManager = wm_scene.instantiate()
	root.add_child(wm)
	await process_frame
	await process_frame

	_report.section("setup")
	var kb := _find_keyboard(wm)
	_report.check("keyboard found under the window manager", kb != null)
	if not kb:
		_report.check("cannot continue without a keyboard", false)
		_report.finish(self)
		return

	var received: Array[InputEventKey] = []
	kb.key_pressed.connect(func(e: InputEventKey): received.append(e))

	# The terminal is the last window WindowManager._ready spawns, so it starts
	# focused and is the one input should reach
	var focused: SWindow = wm.get_focused_window()
	var terminal := focused.content_3d.get_scene_instance() as TerminalUi
	_report.check("the focused window hosts the terminal", terminal != null)

	_report.section("a single virtual keypress")
	kb.on_key_pressed("A", 97, false)
	await process_frame

	_report.check("key_pressed emitted once", received.size() == 1,
			str(received.size()))
	_report.check("the emitted event carries KEY_A",
			received.size() == 1 and received[0].keycode == KEY_A)
	_report.check("KEY_A is not left held in Input",
			not Input.is_physical_key_pressed(KEY_A))
	if terminal:
		_report.check("the terminal received exactly one 'a'",
				terminal.input_line.text == "a", terminal.input_line.text)

	# W is one of the keys the simulator maps to locomotion, so a key left held
	# would show up as a deflected thumbstick rather than only as stray input.
	_report.section("a key the simulator maps to locomotion")
	kb.on_key_pressed("W", 119, false)
	await process_frame

	_report.check("KEY_W is not left held in Input",
			not Input.is_physical_key_pressed(KEY_W))
	_report.check("the simulated left thumbstick stays centred",
			_left_stick() == Vector2.ZERO, str(_left_stick()))
	if terminal:
		_report.check("the terminal received both characters",
				terminal.input_line.text == "aw", terminal.input_line.text)

	_report.finish(self)
