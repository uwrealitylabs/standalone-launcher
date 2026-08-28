class_name TerminalUi
extends Control

@onready var input_line: LineEdit = $VBoxContainer/InputLine
@onready var output_display: RichTextLabel = $VBoxContainer/OutputDisplay

var current_dir: String = OS.get_executable_path().get_base_dir()
var is_running: bool = false

var _current: AsyncCommand = null
# Paragraph holding the "Running..." notice, or -1 when none is showing.
var _running_line := -1
# Where "cd -" goes back to. Empty until the first successful cd.
var _previous_dir := ""


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


## Applies a `cd` argument to `current_dir`, reporting where it ended up or why
## it could not. No argument means home, "-" means the previous directory.
func _change_dir(arg: String) -> void:
	var quoted := arg.length() >= 2 and (
			(arg.begins_with("\"") and arg.ends_with("\""))
			or (arg.begins_with("'") and arg.ends_with("'")))
	var target := arg.substr(1, arg.length() - 2) if quoted else arg

	if target == "-":
		if _previous_dir == "":
			stdout("[color=red]No previous directory[/color]")
			return
		target = _previous_dir

	# Known issue: the rest of the line is taken as part of the path, so
	# "cd ..; pwd" looks for a directory named "..; pwd" and reports it missing.
	# Left that way on purpose: passing the line to a shell instead would run it
	# in a subshell that is then discarded, so pwd would print the parent as
	# though the move had worked, while current_dir stayed put and the next
	# command still ran here - trading a loud failure for a silent wrong one.
	var resolved := _resolve_dir(target)
	if not DirAccess.dir_exists_absolute(resolved):
		stdout("[color=red]Directory not found: " + resolved + "[/color]")
		return
	_previous_dir = current_dir
	current_dir = resolved
	stdout("[color=cyan]Directory changed to: " + current_dir + "[/color]")


## Turns a `cd` argument into an absolute path.
func _resolve_dir(arg: String) -> String:
	var home := OS.get_environment("HOME")
	var path := arg
	if home != "" and (path == "" or path == "~"):
		path = home
	elif home != "" and path.begins_with("~/"):
		path = home.path_join(path.substr(2))
	# Relative paths are resolved here rather than left to the command, because
	# the command runs from wherever the launcher was started, not from
	# current_dir, and would otherwise land somewhere else entirely.
	if not path.begins_with("/"):
		path = current_dir.path_join(path)
	return path.simplify_path()


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
	var line := cmd.strip_edges()
	if line == "cd" or line.begins_with("cd "):
		_change_dir(line.substr(2).strip_edges())
		return

	if line == "clear":
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
