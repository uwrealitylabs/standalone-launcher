extends Node3D

## --- Configuration ---
@onready var terminal_screen = $TerminalScreen 

## --- Variables ---
var output_display: RichTextLabel 
var input_line: LineEdit 
var current_dir: String = "/" # Track your folder location

func _ready():
	await get_tree().process_frame
	
	# 1. Connect to the 2D UI
	var ui_root = terminal_screen.get_scene_instance()
	if ui_root:
		output_display = ui_root.find_child("OutputDisplay")
		input_line = ui_root.find_child("InputLine")
	
	# 2. Connect the Input Box
	if input_line:
		# This signal fires when you press ENTER inside the box
		input_line.connect("text_submitted", _on_command_submitted)
		input_line.grab_focus() # Auto-select the box so you can type immediately
	
	# 3. Boot Messages
	if output_display:
		append_text("[color=cyan]Reality Labs Shell Initialized...[/color]")
		append_text("[color=green]Terminal Ready...[/color]")

## --- The Core Logic ---

func _on_command_submitted(command: String):
	# Step A: Write down the command you just wrote (The Echo)
	# We add a ">" so it looks like a real terminal prompt
	append_text("[color=gray]> " + command + "[/color]")
	
	# Step B: Make the command actually work (The Execution)
	execute_command(command)
	
	# Step C: Clear the box so you are ready for the next command
	if input_line:
		input_line.clear()

func execute_command(command: String):
	# 1. Setup for Windows vs Linux
	var shell = "cmd.exe" if OS.get_name() == "Windows" else "bash"
	var flag = "/c" if OS.get_name() == "Windows" else "-c"
	
	# 2. Handle specific commands like 'cd' manually (since OS.execute spawns new shells)
	if command.begins_with("cd "):
		var new_dir = command.trim_prefix("cd ").strip_edges()
		current_dir = new_dir # Logic to update internal tracker would go here
		append_text("Directory changed to: " + new_dir)
		return

	# 3. Run the command on the OS
	var output = []
	var exit_code = OS.execute(shell, [flag, command], output)
	
	# 4. Show the result
	if exit_code == 0:
		# If output is empty (like a successful 'mkdir'), just print nothing or "Done"
		if output.size() > 0 and output[0].strip_edges() != "":
			append_text(output[0])
	else:
		append_text("[color=red]Error: Command failed or not found.[/color]")

## --- Helper Functions ---
func append_text(new_text: String):
	if output_display:
		output_display.append_text("\n" + new_text)
		# Scroll to the bottom so you always see the newest line
		output_display.scroll_to_line(output_display.get_line_count())
