extends SceneTree
# Verification script for virtual-keyboard input isolation. Run:
#   godot --headless --xr-mode off -s res://tests/virtual_keyboard_input_test.gd


var _failures := 0


func _check(label: String, cond: bool) -> void:
	if cond:
		print("PASS: " + label)
	else:
		_failures += 1
		print("FAIL: " + label)


# The simulator maps WASD onto the left thumbstick by polling Input directly, so
# its own mapping function is the most faithful check that a virtual keypress
# left no trace in the global held-key state.
func _left_stick() -> Vector2:
	var sim := root.get_node_or_null("XrSimulator")
	if sim:
		return sim.vector_key_mapping(KEY_D, KEY_A, KEY_W, KEY_S)
	# Autoload absent under -s: the function reads only Input, so a bare
	# instance answers the same question
	var script: GDScript = load("res://addons/xr-simulator/XRSimulator.gd")
	return script.new().vector_key_mapping(KEY_D, KEY_A, KEY_W, KEY_S)


## The XRToolsVirtualKeyboard2D inside the WindowManager's keyboard.
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

	var kb := _find_keyboard(wm)
	_check("keyboard found under the window manager", kb != null)
	if not kb:
		print("RESULT: %d FAILURES" % (_failures + 1))
		quit(1)
		return

	var received: Array[InputEventKey] = []
	kb.key_pressed.connect(func(e: InputEventKey): received.append(e))

	# The terminal is the last window WindowManager._ready spawns, so it starts
	# focused and is the one input should reach
	var focused: SWindow = wm.get_focused_window()
	var terminal := focused.content_3d.get_scene_instance() as TerminalUi
	_check("focused window hosts the terminal", terminal != null)

	# --- a single virtual keypress ---
	kb.on_key_pressed("A", 97, false)
	await process_frame

	_check("key_pressed emitted once", received.size() == 1)
	_check("emitted event carries KEY_A",
		received.size() == 1 and received[0].keycode == KEY_A)

	# The regression guard: a press with no matching release must never enter
	# the global Input singleton, or it latches as held forever
	_check("KEY_A is not left held in Input",
		not Input.is_physical_key_pressed(KEY_A))

	if terminal:
		_check("terminal received exactly one 'a'",
			terminal.input_line.text == "a")

	# --- a key the simulator maps to locomotion ---
	kb.on_key_pressed("W", 119, false)
	await process_frame

	_check("KEY_W is not left held in Input",
		not Input.is_physical_key_pressed(KEY_W))
	_check("simulated left thumbstick stays centred",
		_left_stick() == Vector2.ZERO)

	if terminal:
		_check("terminal received both characters",
			terminal.input_line.text == "aw")

	print("RESULT: %s" % ("ALL PASS" if _failures == 0 else "%d FAILURES" % _failures))
	quit(1 if _failures else 0)
