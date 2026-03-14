class_name TerminalUi
extends Control

@onready var input_line: LineEdit = $VBoxContainer/InputLine
@onready var output_display: RichTextLabel = $VBoxContainer/OutputDisplay

var current_dir: String = OS.get_executable_path().get_base_dir()
var is_running: bool = false


func _ready():
	stdout("[color=yellow]SYSTEM READY[/color]")
	input_line.text_submitted.connect(_on_submit)


func _process(_delta):
	if output_display.size.y < 10:
		output_display.custom_minimum_size.y = 200


## Handles key input into the terminal
func key_input(input: InputEventKey) -> void:
	print("input received")
	if not input.pressed:
		return
	match input.keycode:
		KEY_BACKSPACE:
			input_line.delete_char_at_caret()
		KEY_ENTER:
			input_line.text_submitted.emit(input_line.text)
		KEY_LEFT:
			input_line.caret_column -= 1
		KEY_RIGHT:
			input_line.caret_column += 1
		_:
			var c := char(input.unicode)
			if c != "":
				input_line.insert_text_at_caret(c)


func stdout(text: String):
	output_display.append_text(text + "\n")
	output_display.scroll_to_line(output_display.get_line_count())


func _on_submit(cmd: String) -> void:
	if cmd == "":
		return

	# prevent running multiple commands at once
	if is_running:
		stdout("[color=yellow]Command still running, please wait...[/color]")
		return

	stdout("[color=gray]> " + cmd + "[/color]")
	input_line.text = ""

	# built-in commands
	if cmd.begins_with("cd "):
		var new_dir = cmd.substr(3).strip_edges()
		if DirAccess.dir_exists_absolute(new_dir):
			current_dir = new_dir
			stdout("[color=cyan]Directory changed to: " + current_dir + "[/color]")
		else:
			stdout("[color=red]Directory not found: " + new_dir + "[/color]")
		return

	if cmd == "clear":
		output_display.clear()
		return

	# run command asynchronously
	is_running = true
	stdout("[color=yellow]Running...[/color]")

	var result = await AsyncCommand.run(current_dir, cmd)

	is_running = false

	if result.output.strip_edges() != "":
		if result.exit_code == 0:
			stdout(result.output.strip_edges())
		else:
			stdout("[color=red]" + result.output.strip_edges() + "[/color]")
	else:
		if result.exit_code == 0:
			stdout("[color=green]Done (exit code 0)[/color]")
		else:
			stdout("[color=red]No output. Exit code: " + str(result.exit_code) + "[/color]")
