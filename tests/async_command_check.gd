extends SceneTree

## Verifies AsyncCommand against a real shell.
##
## Run with:
##   godot --headless --xr-mode off --path . \
##       --script res://tests/async_command_check.gd
##
## --xr-mode off is required: without an OpenXR runtime, initialization raises a
## modal alert that never gets dismissed and the run hangs.
##
## Unix only: every fixture command is POSIX shell. The suite takes roughly ten
## seconds, most of it spent proving that the timeout and cancel paths really do
## return early rather than merely returning eventually.

const Report := preload("res://tests/support/report.gd")

const WORKSPACE_PREFIX := "async_cmd_"

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

	await _check_output_capture()
	await _check_redirect_containment()
	await _check_working_directory()
	await _check_stdin_is_closed()
	await _check_output_streams()
	await _check_timeout()
	await _check_cancel()
	await _check_dropped_reference()
	await _check_concurrent_commands()
	_check_no_workspaces_left("after the whole suite")
	_report.finish(self)


## stdout, stderr and the exit code all survive the trip through the files.
func _check_output_capture() -> void:
	_report.section("output capture")
	var r := await _run_cmd("echo hello")
	_report.check("stdout is captured", r.output.strip_edges() == "hello", str(r))
	_report.check("a successful command exits 0", r.exit_code == 0, str(r))

	r = await _run_cmd("echo oops 1>&2")
	_report.check("stderr is captured too", r.output.strip_edges() == "oops", str(r))

	r = await _run_cmd("exit 3")
	_report.check("a failing exit code is reported", r.exit_code == 3, str(r))

	r = await _run_cmd("echo hello")
	_report.check("neither flag is set on an ordinary run",
			not r.timed_out and not r.cancelled, str(r))


## The command must not be able to reach past its own output redirection.
func _check_redirect_containment() -> void:
	_report.section("redirect containment")
	var r := await _run_cmd("echo one; echo two")
	_report.check("both halves of a ';' list are captured",
			r.output.strip_edges() == "one\ntwo", str(r))

	r = await _run_cmd("true && echo chained")
	_report.check("a '&&' chain is captured", r.output.strip_edges() == "chained", str(r))

	r = await _run_cmd("echo kept # trailing comment")
	_report.check("a trailing comment cannot swallow the redirect",
			r.output.strip_edges() == "kept", str(r))

	# A command that exits on its own still has to yield both halves of the
	# result: the output it produced first, and an exit code.
	r = await _run_cmd("echo before; exit 7")
	_report.check("output survives an inline exit", r.output.strip_edges() == "before", str(r))
	_report.check("an inline exit still reports its code", r.exit_code == 7, str(r))


func _check_working_directory() -> void:
	_report.section("working directory")
	var r := await _run_cmd("pwd", "/tmp")
	_report.check("the command runs in the requested directory",
			r.output.strip_edges() == "/tmp", str(r))

	r = await _run_cmd("echo should_not_run", "/no/such/directory")
	_report.check("an unusable directory fails instead of running elsewhere",
			r.exit_code != 0, str(r))
	_report.check("an unusable directory does not run the command",
			not r.output.contains("should_not_run"), str(r))


## A command that reads stdin must see EOF, not block forever.
func _check_stdin_is_closed() -> void:
	_report.section("stdin")
	var started := Time.get_ticks_msec()
	var r := await _run_cmd("cat")
	var elapsed := Time.get_ticks_msec() - started
	_report.check("a stdin reader finishes on its own", elapsed < 5000, "%dms" % elapsed)
	_report.check("a stdin reader exits cleanly", r.exit_code == 0, str(r))


## Output has to reach the caller while the command is still running, and the
## pieces have to add up to exactly what the finished result reports.
func _check_output_streams() -> void:
	_report.section("streaming output")
	var cmd := AsyncCommand.new()
	var chunks: Array = []
	cmd.output.connect(func(chunk: String) -> void: chunks.append(chunk))
	cmd.start("/tmp", "echo early; sleep 2; echo late", 10)

	await create_timer(1.0).timeout
	var midway := _joined(chunks)
	_report.check("output arrives before the command has ended",
			midway.contains("early"), midway)
	_report.check("output still to come has not arrived early",
			not midway.contains("late"), midway)

	var r: Dictionary = await cmd.finished
	_report.check("the pieces add up to the whole output",
			_joined(chunks) == r.output, "%s vs %s" % [_joined(chunks), r.output])
	_check_no_workspaces_left("after a streamed command")


func _joined(chunks: Array) -> String:
	var text := ""
	for chunk in chunks:
		text += chunk
	return text


func _check_timeout() -> void:
	_report.section("timeout")
	var started := Time.get_ticks_msec()
	var r := await _run_cmd("echo partial; sleep 30", "/tmp", 2)
	var elapsed := Time.get_ticks_msec() - started
	_report.check("a runaway command is stopped near its deadline",
			elapsed < 12000, "%dms" % elapsed)
	_report.check("the timeout is reported as such", r.timed_out, str(r))
	_report.check("a timeout is not reported as a cancel", not r.cancelled, str(r))
	_report.check("what the command printed before it was stopped is kept",
			r.output.strip_edges() == "partial", str(r))
	_check_no_workspaces_left("after a timeout")


func _check_cancel() -> void:
	_report.section("cancel")
	var cmd := AsyncCommand.new()
	var started := Time.get_ticks_msec()
	cmd.start("/tmp", "sleep 30", 30)
	await create_timer(0.5).timeout
	_report.check("a running command is not yet finished", not cmd.is_finished)
	cmd.cancel()
	var r: Dictionary = await cmd.finished
	var elapsed := Time.get_ticks_msec() - started
	_report.check("cancel returns long before the deadline", elapsed < 10000, "%dms" % elapsed)
	_report.check("the cancel is reported as such", r.cancelled, str(r))
	_report.check("a cancel is not reported as a timeout", not r.timed_out, str(r))
	_report.check("the command is finished afterwards", cmd.is_finished)
	_check_no_workspaces_left("after a cancel")


## Dropping the caller's reference must not strand the command: a RefCounted
## whose last reference goes away takes its pending coroutine, and therefore its
## temp files, with it.
func _check_dropped_reference() -> void:
	_report.section("dropped reference")
	var cmd := AsyncCommand.new()
	cmd.start("/tmp", "echo orphan", 10)
	cmd = null
	await create_timer(3.0).timeout
	_check_no_workspaces_left("after the caller dropped its reference")


## Two commands started in the same frame must not share a workspace.
func _check_concurrent_commands() -> void:
	_report.section("concurrent commands")
	var first := AsyncCommand.new()
	var second := AsyncCommand.new()
	first.start("/tmp", "echo first", 10)
	second.start("/tmp", "echo second", 10)
	var r1: Dictionary = await first.finished
	var r2: Dictionary = await second.finished
	_report.check("the first command keeps its own output",
			r1.output.strip_edges() == "first", str(r1))
	_report.check("the second command keeps its own output",
			r2.output.strip_edges() == "second", str(r2))
	_check_no_workspaces_left("after two concurrent commands")


func _run_cmd(command: String, working_dir: String = "/tmp",
		timeout_sec: int = 10) -> Dictionary:
	var cmd := AsyncCommand.new()
	cmd.start(working_dir, command, timeout_sec)
	return await cmd.finished


## Every command must take its scratch directory with it when it finishes.
func _check_no_workspaces_left(when: String) -> void:
	var left := PackedStringArray()
	var dir := DirAccess.open(OS.get_user_data_dir())
	if dir != null:
		for d in dir.get_directories():
			if d.begins_with(WORKSPACE_PREFIX):
				left.append(d)
	_report.check("no scratch files left %s" % when, left.is_empty(), str(left))

