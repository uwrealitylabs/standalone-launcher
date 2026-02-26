extends Node3D

@export var xr_keyboard: Node3D

var ui_node: Control
var current_dir: String = "D:/Reality Labs/standalone-launcher"

func _ready():
	await get_tree().create_timer(1.0).timeout
	var terminal_nodes = get_tree().get_nodes_in_group("terminal_group")
	if terminal_nodes.size() > 0:
		ui_node = terminal_nodes[0]
		_connect_keyboard()
		
		# Disconnect first to avoid double-connecting
		if ui_node.input_line.text_submitted.is_connected(_on_terminal_submit):
			ui_node.input_line.text_submitted.disconnect(_on_terminal_submit)
		ui_node.input_line.text_submitted.connect(_on_terminal_submit)
		
		ui_node.display_text("[color=green]LINK ESTABLISHED.[/color]")
	else:
		push_error("No terminal node found in group 'terminal_group'!")

func _connect_keyboard():
	if not xr_keyboard or not ui_node: return
	var kb_2d = xr_keyboard.get_scene_instance()
	if not kb_2d: return
	if kb_2d.has_signal("key_pressed") and not kb_2d.key_pressed.is_connected(ui_node.vr_type):
		kb_2d.key_pressed.connect(ui_node.vr_type)
	if kb_2d.has_signal("backspace_pressed") and not kb_2d.backspace_pressed.is_connected(ui_node.vr_backspace):
		kb_2d.backspace_pressed.connect(ui_node.vr_backspace)
	var sig = "text_submitted" if kb_2d.has_signal("text_submitted") else "enter_pressed"
	if not kb_2d.is_connected(sig, _on_terminal_submit):
		kb_2d.connect(sig, _on_terminal_submit)

func _on_terminal_submit(_args = ""):
	if not ui_node:
		push_error("ui_node is null!")
		return
	
	var cmd = ui_node.vr_enter()
	cmd = cmd.strip_edges()
	if cmd == "": return
	
	ui_node.display_text("[color=gray]> " + cmd + "[/color]")
	
	# Built-in commands
	if cmd.begins_with("cd "):
		var new_dir = cmd.substr(3).strip_edges()
		if DirAccess.dir_exists_absolute(new_dir):
			current_dir = new_dir
			ui_node.display_text("[color=cyan]Directory changed to: " + current_dir + "[/color]")
		else:
			ui_node.display_text("[color=red]Directory not found: " + new_dir + "[/color]")
		return
	
	if cmd == "clear":
		ui_node.output_display.clear()
		return
	
	# Run command
	var out = []
	var full_cmd = "cd /d \"" + current_dir + "\" && " + cmd
	var exit_code = OS.execute("cmd.exe", ["/c", full_cmd], out, true, true)
	
	if out.size() > 0 and out[0].strip_edges() != "":
		ui_node.display_text(out[0])
	else:
		ui_node.display_text("[color=red]No output. Exit code: " + str(exit_code) + "[/color]")
