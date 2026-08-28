extends SceneTree

## Verifies the terminal's built-in cd: what each form of the argument means,
## and that what gets stored is always an absolute path.
##
## Run with:
##   godot --headless --xr-mode off --path . \
##       --script res://tests/terminal_cd_test.gd
##
## --xr-mode off is required: without an OpenXR runtime, initialization raises a
## modal alert that never gets dismissed and the run hangs.
##
## Unix only: the fixture paths are POSIX.

const Report := preload("res://tests/support/report.gd")

const TERMINAL_SCENE := "res://project/shell/terminal_ui.tscn"

var _report := Report.new()


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if OS.get_name() == "Windows":
		# Reported as a pass with no checks so the run still ends in the summary
		# line the harnesses look for.
		_report.section("skipped - the fixtures assume POSIX paths")
		_report.finish(self)
		return

	_check_absolute()
	_check_relative()
	_check_home()
	_check_previous()
	_check_quoted()
	_check_trailing_shell_syntax()
	_check_missing()
	_report.finish(self)


func _check_absolute() -> void:
	_report.section("an absolute path")
	var terminal := _new_terminal()
	_cd(terminal, "/usr")
	_report.check("is used as given", terminal.current_dir == "/usr", terminal.current_dir)
	terminal.queue_free()


## The regression this guards: a relative argument used to be stored unresolved,
## and the command then resolved it against the launcher's own directory rather
## than the terminal's, so it ran somewhere the terminal was not showing.
func _check_relative() -> void:
	_report.section("a relative path")
	var terminal := _new_terminal()

	_cd(terminal, "/usr")
	_cd(terminal, "share")
	_report.check("is resolved against the terminal's directory",
			terminal.current_dir == "/usr/share", terminal.current_dir)

	_cd(terminal, "..")
	_report.check("'..' goes up one level",
			terminal.current_dir == "/usr", terminal.current_dir)

	_cd(terminal, "..")
	_report.check("'..' twice goes up twice, rather than staying put",
			terminal.current_dir == "/", terminal.current_dir)

	_cd(terminal, ".")
	_report.check("'.' stays where it is", terminal.current_dir == "/", terminal.current_dir)
	terminal.queue_free()


func _check_home() -> void:
	_report.section("the home directory")
	var home := OS.get_environment("HOME")
	var terminal := _new_terminal()

	_cd(terminal, "/usr")
	_cd(terminal, "")
	_report.check("a bare cd goes home", terminal.current_dir == home, terminal.current_dir)

	_cd(terminal, "/usr")
	_cd(terminal, "~")
	_report.check("'~' goes home", terminal.current_dir == home, terminal.current_dir)

	# Checked against home's parent rather than a named subdirectory, which
	# would tie the suite to whatever happens to exist under home.
	_cd(terminal, "/usr")
	_cd(terminal, "~/..")
	_report.check("'~/' is expanded before the rest of the path is joined on",
			terminal.current_dir == home.get_base_dir(), terminal.current_dir)
	terminal.queue_free()


func _check_quoted() -> void:
	_report.section("a quoted path")
	var terminal := _new_terminal()

	_cd(terminal, "\"/tmp\"")
	_report.check("double quotes are stripped", terminal.current_dir == "/tmp",
			terminal.current_dir)

	_cd(terminal, "/usr")
	_cd(terminal, "'/tmp'")
	_report.check("single quotes are stripped too", terminal.current_dir == "/tmp",
			terminal.current_dir)
	terminal.queue_free()


## A cd carrying anything after the path is a known gap: the whole rest of the
## line is taken as part of the path. What this pins is that the gap stays a
## safe one - the command does not run and the terminal does not move, so it
## cannot leave the terminal pointing somewhere it is not showing.
func _check_trailing_shell_syntax() -> void:
	_report.section("a cd with more of a command after it")
	for line in ["..; pwd", "/tmp && ls", "/tmp | cat", "/tmp &", "$HOME"]:
		var terminal := _new_terminal()
		_cd(terminal, "/usr")
		_cd(terminal, line)
		_report.check("'cd %s' leaves the directory alone" % line,
				terminal.current_dir == "/usr", terminal.current_dir)
		terminal.queue_free()


func _check_previous() -> void:
	_report.section("the previous directory")
	var terminal := _new_terminal()

	_cd(terminal, "/usr")
	_cd(terminal, "/tmp")
	_cd(terminal, "-")
	_report.check("'-' goes back", terminal.current_dir == "/usr", terminal.current_dir)
	terminal.queue_free()


func _check_missing() -> void:
	_report.section("a directory that is not there")
	var terminal := _new_terminal()

	_cd(terminal, "/usr")
	_cd(terminal, "/no/such/directory")
	_report.check("leaves the terminal where it was",
			terminal.current_dir == "/usr", terminal.current_dir)
	_report.check("says so", _text(terminal).contains("Directory not found"),
			_text(terminal))
	terminal.queue_free()


func _new_terminal() -> TerminalUi:
	var terminal: TerminalUi = load(TERMINAL_SCENE).instantiate()
	root.add_child(terminal)
	return terminal


## Sends a cd the way the input line does. An empty `arg` sends a bare "cd".
func _cd(terminal: TerminalUi, arg: String) -> void:
	terminal.input_line.text_submitted.emit("cd" if arg == "" else "cd " + arg)


func _text(terminal: TerminalUi) -> String:
	return terminal.output_display.get_parsed_text()
