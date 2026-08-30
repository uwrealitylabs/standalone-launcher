class_name AsyncCommand
extends RefCounted

## Runs one shell command without blocking the scene, and reports the result on
## [signal finished].
##
##     var cmd := AsyncCommand.new()
##     cmd.start("/home/pi", "ls -la")
##     var result = await cmd.finished   # {"output", "exit_code",
##                                       #  "timed_out", "cancelled"}
##
## Output also arrives as it is produced, on [signal output], for a caller that
## wants to show a long command's progress rather than wait for all of it.
##
## A command that never ends is stopped at `timeout_sec`, and [method cancel]
## stops one early, so the await always returns. One instance runs one command.
##
## Godot offers no non-blocking way to read a child's output, so the command is
## wrapped in a generated script that redirects into a scratch directory, which
## is polled once per frame.

signal finished(result: Dictionary)

## Carries each new piece of the command's output as it appears. The pieces
## concatenate to everything the command printed, and one can stop mid-line, so
## a listener must append rather than treat it as a whole line.
signal output(chunk: String)

const DEFAULT_TIMEOUT_SEC := 30

# How long the script waits between asking the command to stop and killing it.
const _KILL_GRACE_SEC := 2

# How often the output file is checked for new text. Deliberately coarser than
# the frame rate, since the file is reopened on every check.
const _OUTPUT_POLL_MSEC := 50

# Added to the command's own timeout before this side stops waiting. Only
# reached when the script itself dies without writing an exit code, since the
# script is otherwise the one enforcing the deadline.
const _BACKSTOP_GRACE_SEC := 8

var is_finished := false

## The deadline this command was started with, in seconds.
var timeout_sec := DEFAULT_TIMEOUT_SEC

# Distinguishes two commands started in the same millisecond, which would
# otherwise be handed the same scratch directory and overwrite each other.
static var _serial := 0

var _workspace := ""
var _working_dir := ""
# Bytes of the output file already sent on [signal output]. Bytes rather than
# characters, because it indexes into the file and not into the decoded text.
var _streamed := 0
var _cancel_requested := false
# Holds this object alive until the command ends, and is released by _finish.
# Dropping a RefCounted's last reference takes the coroutine running inside it
# too, stranding the child process and the scratch directory.
var _keepalive: AsyncCommand = null


## Starts `command` in `working_dir`. Returns at once; the result arrives on
## [signal finished]. Calling this twice on one instance is not supported.
func start(working_dir: String, command: String,
		seconds: int = DEFAULT_TIMEOUT_SEC) -> void:
	_keepalive = self
	timeout_sec = seconds
	_working_dir = working_dir
	_serial += 1
	_workspace = "%s/async_cmd_%d_%d" % [OS.get_user_data_dir(),
			Time.get_ticks_usec(), _serial]
	DirAccess.make_dir_recursive_absolute(_workspace)
	_wait_for(command)


## Stops the command early. The result still arrives on [signal finished], with
## "cancelled" set. Does nothing once the command has finished.
func cancel() -> void:
	if is_finished or _cancel_requested:
		return
	_cancel_requested = true
	# The script polls for this file and stops the command the same way it does
	# on a timeout, so a cancel comes back through the ordinary exit path.
	var flag := FileAccess.open(_path("cancel"), FileAccess.WRITE)
	if flag != null:
		flag.close()


func _path(name: String) -> String:
	return _workspace + "/" + name


func _wait_for(command: String) -> void:
	var script_path := _write_script(command)
	var launcher := "cmd.exe" if OS.get_name() == "Windows" else "bash"
	var args := ["/c", script_path] if OS.get_name() == "Windows" else [script_path]
	var pid := OS.create_process(launcher, args)
	if pid == -1:
		_finish("could not start %s\n" % launcher, -1, false)
		return

	var exit_path := _path("exit")
	var backstop := Time.get_ticks_msec() + (timeout_sec + _BACKSTOP_GRACE_SEC) * 1000
	var backstopped := false
	var next_poll := 0
	while not FileAccess.file_exists(exit_path):
		if Time.get_ticks_msec() > backstop:
			backstopped = true
			break
		if Time.get_ticks_msec() >= next_poll:
			next_poll = Time.get_ticks_msec() + _OUTPUT_POLL_MSEC
			_stream_new_output()
		await Engine.get_main_loop().process_frame

	# The command gets to print between the last poll and its exit, and the exit
	# file only appears once it is done, so this last look is what makes the
	# streamed pieces add up to the whole output.
	_stream_new_output()

	var output := _read(_path("out"))
	var exit_code := -1
	var exit_text := _read(exit_path).strip_edges()
	if exit_text.is_valid_int():
		exit_code = int(exit_text)
	if backstopped:
		output += "\n[gave up waiting after %ds]\n" % (timeout_sec + _BACKSTOP_GRACE_SEC)

	_finish(output, exit_code,
			backstopped or FileAccess.file_exists(_path("timeout")))


## Sends whatever has been appended to the output file since the last call.
func _stream_new_output() -> void:
	var file := FileAccess.open(_path("out"), FileAccess.READ)
	if file == null:
		return
	var length := file.get_length()
	if length <= _streamed:
		file.close()
		return
	file.seek(_streamed)
	# get_buffer, rather than get_as_text, because only this reads from the
	# seek position: the text form starts over at the top of the file.
	var chunk := file.get_buffer(length - _streamed).get_string_from_utf8()
	file.close()
	_streamed = length
	if chunk != "":
		output.emit(chunk)


func _read(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text := file.get_as_text()
	file.close()
	return text


func _finish(output: String, exit_code: int, timed_out: bool) -> void:
	_remove_workspace()
	is_finished = true
	# Moved into a local first: clearing the member can drop the last reference
	# to this object, and it must outlive the emit below.
	var keeper := _keepalive
	_keepalive = null
	keeper.finished.emit({
		"output": output,
		"exit_code": exit_code,
		"timed_out": timed_out,
		"cancelled": _cancel_requested,
	})


func _remove_workspace() -> void:
	var dir := DirAccess.open(_workspace)
	if dir == null:
		return
	for f in dir.get_files():
		DirAccess.remove_absolute(_path(f))
	DirAccess.remove_absolute(_workspace)


func _write_script(command: String) -> String:
	var is_windows := OS.get_name() == "Windows"
	var script_path := _path("cmd.bat" if is_windows else "cmd.sh")
	var content := (_windows_script(command) if is_windows
			else _posix_script(command))
	var file := FileAccess.open(script_path, FileAccess.WRITE)
	file.store_string(content)
	file.close()
	return script_path


## Builds the shell script that runs `command` and records how it ended.
func _posix_script(command: String) -> String:
	# The command sits alone inside a subshell so that nothing it contains can
	# reach the redirection -- written on the same line, a ";", "#" or "exit"
	# would each break it. stdin is closed so a command reading it sees EOF
	# instead of blocking on a terminal that is not there.
	var script := "#!/bin/bash\n(\ncd \"%s\" || exit 1\n%s\n) < /dev/null > \"%s\" 2>&1 &\n" \
			% [_working_dir, command, _path("out")]
	script += "child=$!\n"

	# The watchdog stops the command on either a cancel or the deadline. It is
	# part of the script rather than of the launcher because only the shell
	# knows the process ids involved.
	script += "(\nwaited=0\nwhile :; do\n"
	script += "\t[ -f \"%s\" ] && break\n" % _path("cancel")
	script += "\tif [ \"$waited\" -ge %d ]; then\n" % timeout_sec
	script += "\t\t: > \"%s\"\n" % _path("timeout")
	script += "\t\tbreak\n\tfi\n"
	script += "\tkill -0 \"$child\" 2>/dev/null || exit 0\n"
	script += "\tsleep 1\n\twaited=$((waited+1))\n"
	script += "done\n"
	# The children are noted before the subshell dies, because once it is gone
	# they are reparented and there is no way back to them. Killing it first
	# also keeps it from reporting their deaths into the captured output.
	script += "kids=$(pgrep -P \"$child\" 2>/dev/null)\n"
	script += "kill -TERM \"$child\" 2>/dev/null\n"
	script += "[ -n \"$kids\" ] && kill -TERM $kids 2>/dev/null\n"
	script += "sleep %d\n" % _KILL_GRACE_SEC
	script += "kill -KILL \"$child\" 2>/dev/null\n"
	script += "[ -n \"$kids\" ] && kill -KILL $kids 2>/dev/null\n"
	script += ") &\nguard=$!\n"

	# From here the script's own stderr is only bash's killed-job notice, which
	# is expected and would otherwise print on the launcher's console.
	script += "exec 2>/dev/null\n"
	script += "wait \"$child\"\ncode=$?\nkill \"$guard\" 2>/dev/null\n"
	# Renamed into place: the launcher treats this file's existence as the
	# signal that the command is over, so it must appear already complete.
	script += "echo \"$code\" > \"%s.part\"\n" % _path("exit")
	script += "mv \"%s.part\" \"%s\"\n" % [_path("exit"), _path("exit")]
	return script


## Builds the batch equivalent. There is no watchdog here: batch has no clean
## way to wait on a process id, so a runaway command on Windows is stopped by
## the launcher giving up rather than by the script.
func _windows_script(command: String) -> String:
	var script := "@echo off\n"
	script += "cd /d \"%s\" || exit /b 1\n" % _working_dir
	script += "(\n%s\n) < NUL > \"%s\" 2>&1\n" % [command, _path("out")]
	script += "echo %%ERRORLEVEL%%> \"" + _path("exit") + ".part\"\n"
	script += "move /Y \"%s.part\" \"%s\" >NUL\n" % [_path("exit"), _path("exit")]
	return script
