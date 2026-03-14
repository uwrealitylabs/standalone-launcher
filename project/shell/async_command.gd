class_name AsyncCommand
extends RefCounted

## Runs a shell command without freezing the scene.
## Supports both Windows and Linux.
## Returns a Dictionary with "output" (String) and "exit_code" (int).

static func run(working_dir: String, command: String) -> Dictionary:
	var timestamp = str(Time.get_ticks_msec())
	var output_path = OS.get_user_data_dir() + "/out_" + timestamp + ".txt"
	var exit_path = OS.get_user_data_dir() + "/exit_" + timestamp + ".txt"

	var is_windows = OS.get_name() == "Windows"

	if is_windows:
		_run_windows(working_dir, command, output_path, exit_path, timestamp)
	else:
		_run_linux(working_dir, command, output_path, exit_path, timestamp)

	while not FileAccess.file_exists(exit_path):
		await Engine.get_main_loop().process_frame

	for i in 3:
		await Engine.get_main_loop().process_frame

	# read the output
	var output = ""
	if FileAccess.file_exists(output_path):
		var out_file = FileAccess.open(output_path, FileAccess.READ)
		output = out_file.get_as_text()
		out_file.close()

	# read the exit code
	var exit_code = -1
	if FileAccess.file_exists(exit_path):
		var exit_file = FileAccess.open(exit_path, FileAccess.READ)
		var exit_text = exit_file.get_as_text().strip_edges()
		exit_file.close()
		if exit_text.is_valid_int():
			exit_code = int(exit_text)

	# clean up temp files
	DirAccess.remove_absolute(output_path)
	DirAccess.remove_absolute(exit_path)

	if is_windows:
		DirAccess.remove_absolute(OS.get_user_data_dir() + "/cmd_" + timestamp + ".bat")
	else:
		DirAccess.remove_absolute(OS.get_user_data_dir() + "/cmd_" + timestamp + ".sh")

	return { "output": output, "exit_code": exit_code }


static func _run_windows(working_dir: String, command: String, output_path: String, exit_path: String, timestamp: String) -> void:
	var batch_path = OS.get_user_data_dir() + "/cmd_" + timestamp + ".bat"

	var batch_content = "@echo off\n"
	batch_content += "cd /d \"" + working_dir + "\"\n"
	batch_content += command + " > \"" + output_path + "\" 2>&1\n"
	batch_content += "echo %ERRORLEVEL% > \"" + exit_path + "\"\n"

	var batch_file = FileAccess.open(batch_path, FileAccess.WRITE)
	batch_file.store_string(batch_content)
	batch_file.close()

	OS.create_process("cmd.exe", ["/c", batch_path])


static func _run_linux(working_dir: String, command: String, output_path: String, exit_path: String, timestamp: String) -> void:
	var script_path = OS.get_user_data_dir() + "/cmd_" + timestamp + ".sh"

	var script_content = "#!/bin/bash\n"
	script_content += "cd \"" + working_dir + "\"\n"
	script_content += command + " > \"" + output_path + "\" 2>&1\n"
	script_content += "echo $? > \"" + exit_path + "\"\n"

	var script_file = FileAccess.open(script_path, FileAccess.WRITE)
	script_file.store_string(script_content)
	script_file.close()

	OS.create_process("chmod", ["+x", script_path])

	# small delay to let chmod finish
	await Engine.get_main_loop().process_frame

	OS.create_process("bash", [script_path])
