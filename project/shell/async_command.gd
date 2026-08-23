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
## A command that never ends is stopped at `timeout_sec`, and [method cancel]
## stops one early, so the await always returns. One instance runs one command.
##
## Godot offers no non-blocking way to read a child's output, so the command is
## wrapped in a generated script that redirects into a scratch directory, and
## the result is collected by polling that directory once per frame.

signal finished(result: Dictionary)

const DEFAULT_TIMEOUT_SEC := 30

# How long the script waits between asking the command to stop and killing it.
const _KILL_GRACE_SEC := 2

# Added to the command's own timeout before this side stops waiting. Only
# reached when the script itself dies without writing an exit code, since the
# script is otherwise the one enforcing the deadline.
const _BACKSTOP_GRACE_SEC := 8

var is_finished := false

# Distinguishes two commands started in the same millisecond, which would
# otherwise be handed the same scratch directory and overwrite each other.
static var _serial := 0

var _workspace := ""
var _working_dir := ""
var _cancel_requested := false
# A RefCounted whose last reference is dropped takes any coroutine still
# running inside it, so a caller that forgets its handle would leave both the
# child process and the scratch directory behind. This holds the object up
# until the command is done; _finish releases it.
var _keepalive: AsyncCommand = null


## Starts `command` in `working_dir`. Returns at once; the result arrives on
## [signal finished]. Calling this twice on one instance is not supported.
func start(working_dir: String, command: String,
		timeout_sec: int = DEFAULT_TIMEOUT_SEC) -> void:
	_keepalive = self
	_working_dir = working_dir
	_serial += 1
	_workspace = "%s/async_cmd_%d_%d" % [OS.get_user_data_dir(),
			Time.get_ticks_usec(), _serial]
	DirAccess.make_dir_recursive_absolute(_workspace)
	_wait_for(command, timeout_sec)


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


func _wait_for(command: String, timeout_sec: int) -> void:
	var script_path := _write_script(command, timeout_sec)
	var launcher := "cmd.exe" if OS.get_name() == "Windows" else "bash"
	var args := ["/c", script_path] if OS.get_name() == "Windows" else [script_path]
	var pid := OS.create_process(launcher, args)
	if pid == -1:
		_finish("could not start %s\n" % launcher, -1, false)
		return

	var exit_path := _path("exit")
	var backstop := Time.get_ticks_msec() + (timeout_sec + _BACKSTOP_GRACE_SEC) * 1000
	var backstopped := false
	while not FileAccess.file_exists(exit_path):
		if Time.get_ticks_msec() > backstop:
			backstopped = true
			break
		await Engine.get_main_loop().process_frame

	var output := _read(_path("out"))
	var exit_code := -1
	var exit_text := _read(exit_path).strip_edges()
	if exit_text.is_valid_int():
		exit_code = int(exit_text)
	if backstopped:
		output += "\n[gave up waiting after %ds]\n" % (timeout_sec + _BACKSTOP_GRACE_SEC)

	_finish(output, exit_code,
			backstopped or FileAccess.file_exists(_path("timeout")))


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


func _write_script(command: String, timeout_sec: int) -> String:
	var is_windows := OS.get_name() == "Windows"
	var script_path := _path("cmd.bat" if is_windows else "cmd.sh")
	var content := (_windows_script(command) if is_windows
			else _posix_script(command, timeout_sec))
	var file := FileAccess.open(script_path, FileAccess.WRITE)
	file.store_string(content)
	file.close()
	return script_path


## Builds the shell script that runs `command` and records how it ended.
func _posix_script(command: String, timeout_sec: int) -> String:
	# The command sits alone inside a subshell so that nothing it contains can
	# reach the redirection: written on the same line, a ";" would send only
	# the last part to the output file, a "#" would comment the redirect out,
	# and an "exit" would skip the exit-code line and leave the caller waiting
	# for a file that never arrives. stdin is closed so that a command reading
	# it sees EOF instead of blocking on a terminal that is not there.
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
	script += "\t\techo \"[timed out after %ds]\" >> \"%s\"\n" % [timeout_sec, _path("out")]
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

	# Past this point the only thing the script itself writes to stderr is
	# bash's notice that a background job was killed, which is expected here and
	# would otherwise print on the launcher's console after every command.
	script += "exec 2>/dev/null\n"
	script += "wait \"$child\"\ncode=$?\nkill \"$guard\" 2>/dev/null\n"
	# Written under a temporary name and moved into place, because the launcher
	# treats the file's existence as the signal that the command is over and a
	# rename is the only way to make it appear already complete.
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
