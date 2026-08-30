extends SceneTree

## Verifies that the terminal's "Running..." notice lasts exactly as long as the
## command does, whichever way the command ends.
##
## Run with:
##   godot --headless --xr-mode off --path . \
##       --script res://tests/terminal_running_notice_test.gd
##
## --xr-mode off is required: without it a modal OpenXR alert hangs the run.
##
## Unix only: the fixture commands are POSIX shell. The cancel case spends a few
## seconds proving the notice goes away on that path too.

const Report := preload("res://tests/support/report.gd")

const TERMINAL_SCENE := "res://project/shell/terminal_ui.tscn"
const NOTICE := "Running..."

var _report := Report.new()


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if OS.get_name() == "Windows":
		# Reported as a pass with no checks so the run still ends in the summary
		# line the harnesses look for.
		_report.section("skipped - the fixtures assume a POSIX shell")
		_report.finish(self)
		return

	await _check_successful_command()
	await _check_failing_command()
	await _check_cancelled_command()
	_report.finish(self)


func _check_successful_command() -> void:
	_report.section("a command that succeeds")
	var terminal := _new_terminal()
	_submit(terminal, "echo hello")

	_report.check("the notice shows while the command runs",
			_text(terminal).contains(NOTICE), _text(terminal))
	await _wait_for_idle(terminal)

	_report.check("the notice is gone once the command is done",
			not _text(terminal).contains(NOTICE), _text(terminal))
	_report.check("the command's own output is kept",
			_text(terminal).contains("hello"), _text(terminal))
	terminal.queue_free()


func _check_failing_command() -> void:
	_report.section("a command that fails")
	var terminal := _new_terminal()
	_submit(terminal, "echo nope 1>&2; exit 3")
	await _wait_for_idle(terminal)

	_report.check("the notice is gone after a failure",
			not _text(terminal).contains(NOTICE), _text(terminal))
	_report.check("the error output is kept",
			_text(terminal).contains("nope"), _text(terminal))
	terminal.queue_free()


func _check_cancelled_command() -> void:
	_report.section("a command that is cancelled")
	var terminal := _new_terminal()
	_submit(terminal, "sleep 30")
	await create_timer(0.5).timeout
	_report.check("the notice is still showing mid-run",
			_text(terminal).contains(NOTICE), _text(terminal))

	_submit(terminal, "cancel")
	await _wait_for_idle(terminal, 20000)

	_report.check("the notice is gone after a cancel",
			not _text(terminal).contains(NOTICE), _text(terminal))
	_report.check("the cancel is still reported",
			_text(terminal).contains("Cancelled."), _text(terminal))
	terminal.queue_free()


func _new_terminal() -> TerminalUi:
	var terminal: TerminalUi = load(TERMINAL_SCENE).instantiate()
	root.add_child(terminal)
	return terminal


## Sends `cmd` the way the input line does, and returns once the command has
## started rather than once it has finished.
func _submit(terminal: TerminalUi, cmd: String) -> void:
	terminal.input_line.text_submitted.emit(cmd)


func _text(terminal: TerminalUi) -> String:
	return terminal.output_display.get_parsed_text()


func _wait_for_idle(terminal: TerminalUi, timeout_ms: int = 10000) -> void:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while terminal.is_running and Time.get_ticks_msec() < deadline:
		await process_frame
	_report.check("the command finished within %dms" % timeout_ms,
			not terminal.is_running)
