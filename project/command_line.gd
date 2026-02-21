extends Node3D

@export var xr_keyboard: Node3D # Drag 'VirtualKeyboard' here!

var ui_node: Control
var current_dir: String = "D:/Reality Labs/standalone-launcher"

func _ready():
	await get_tree().create_timer(1.0).timeout
	
	# Find the UI via the group we just made
	var terminal_nodes = get_tree().get_nodes_in_group("terminal_group")
	if terminal_nodes.size() > 0:
		ui_node = terminal_nodes[0]
		_connect_keyboard()
		# Connect the physical 'Enter' key to our execution logic
		ui_node.input_line.text_submitted.connect(_on_terminal_submit)

func _connect_keyboard():
	if xr_keyboard and ui_node:
		var kb_2d = xr_keyboard.get_scene_instance()
		if kb_2d:
			kb_2d.key_pressed.connect(ui_node.vr_type)
			kb_2d.backspace_pressed.connect(ui_node.vr_backspace)
			
			var sig = "text_submitted" if kb_2d.has_signal("text_submitted") else "enter_pressed"
			kb_2d.connect(sig, _on_terminal_submit)

func _on_terminal_submit(_args = ""):
	var cmd = ui_node.vr_enter()
	if cmd.strip_edges() == "": return
	
	ui_node.display_text("[color=gray]> " + cmd + "[/color]")
	
	var out = []
	var full_cmd = "cd /d \"" + current_dir + "\" && " + cmd
	OS.execute("cmd.exe", ["/c", full_cmd], out, true)
	
	if out.size() > 0:
		ui_node.display_text(out[0])
