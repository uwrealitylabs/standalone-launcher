extends Node3D

@export var keyboard_3d: XRToolsViewport2DIn3D
@export var terminal_3d: XRToolsViewport2DIn3D

func _ready() -> void:
	print("check5")
	_connect_keyboard()

## Link virtual keyboard input to the terminal
func _connect_keyboard() -> void:
	var keyboard: XRToolsVirtualKeyboard2D = keyboard_3d.get_scene_instance()
	var terminal_ui: TerminalUi = terminal_3d.get_scene_instance()
	assert(keyboard, "3D keyboard instance not set in inspector.")
	assert(terminal_ui, "3D terminal instance not set in inspector.")
	print(terminal_ui)
	
	if not keyboard.key_pressed.is_connected(terminal_ui.key_input):
		keyboard.key_pressed.connect(terminal_ui.key_input)
