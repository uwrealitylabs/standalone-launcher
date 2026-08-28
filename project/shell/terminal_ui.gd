class_name TerminalUi
extends Control

@onready var input_line: LineEdit = $VBoxContainer/InputLine
@onready var output_display: RichTextLabel = $VBoxContainer/OutputDisplay

var current_dir: String = OS.get_executable_path().get_base_dir()
var is_running: bool = false

var _current: AsyncCommand = null
# Paragraph holding the "Running..." notice, or -1 when none is showing.
var _running_line := -1


func _ready():
	stdout("[color=yellow]SYSTEM READY[/color]")
	input_line.text_submitted.connect(_on_submit)


func _process(_delta):
	if output_display.size.y < 10:
		output_display.custom_minimum_size.y = 200


## Handles key input into the terminal
func _input(input: InputEvent) -> void:
	var key_input: InputEventKey = input as InputEventKey
	if not key_input:
		return
		
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


func _exit_tree() -> void:
	if _current != null and not _current.is_finished:
		_current.cancel()


## Appends `text` to the output as a whole line. Writing to the output any other
## way breaks the one-line-per-paragraph layout the rest of this script assumes.
func stdout(text: String):
	output_display.append_text(text + "\n")
	output_display.scroll_to_line(output_display.get_line_count())


## Removes the "Running..." notice from the output, if one is showing.
func _clear_running_notice() -> void:
	if _running_line < 0:
		return
	output_display.remove_paragraph(_running_line)
	_running_line = -1


func _on_submit(cmd: String) -> void:
	if cmd == "":
		return

	# only one command at a time, so the one way in while it runs is to stop it
	if is_running:
		if cmd.strip_edges() == "cancel":
			stdout("[color=gray]> " + cmd + "[/color]")
			input_line.text = ""
			_current.cancel()
		else:
			stdout("[color=yellow]Command still running, type 'cancel' to stop it[/color]")
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
	# Noted before the "Running..." notice is printed, so it can be taken back out once the
	# command ends. Everything printed while the command runs lands below it, so
	# the index still points at the notice by then.
	#
	# This depends on every write to the output ending in a newline, which leaves
	# the "Running..." notice alone in a paragraph of its own. Anything that writes without
	# a newline would share a paragraph with the notice, and clearing it would take that text too.
	_running_line = output_display.get_paragraph_count() - 1
	stdout("[color=yellow]Running...[/color]")

	_current = AsyncCommand.new()
	_current.start(current_dir, cmd)
	var result: Dictionary = await _current.finished

	var limit := _current.timeout_sec
	_current = null
	is_running = false
	_clear_running_notice()

	# Whatever the command managed to print comes first, even when it was
	# stopped part-way, and is then followed by exactly one line saying how it
	# ended. A stopped command's exit code only says which signal stopped it,
	# so it is not worth showing.
	var body: String = result.output.strip_edges()
	if body != "":
		stdout(body if result.exit_code == 0 else "[color=red]" + body + "[/color]")

	if result.cancelled:
		stdout("[color=yellow]Cancelled.[/color]")
	elif result.timed_out:
		stdout("[color=red]Stopped after " + str(limit) + "s.[/color]")
	elif body == "":
		if result.exit_code == 0:
			stdout("[color=green]Done (exit code 0)[/color]")
		else:
			stdout("[color=red]No output. Exit code: " + str(result.exit_code) + "[/color]")
