class_name AsyncCommand
extends RefCounted

## Runs a shell command without freezing the scene.
## Returns a Dictionary with "output" (String) and "exit_code" (int).

static func run(working_dir: String, command: String) -> Dictionary:
	# build a temp batch file that runs the command and saves output
	var timestamp = str(Time.get_ticks_msec())
	var batch_path = OS.get_user_data_dir() + "/cmd_" + timestamp + ".bat"
	var output_path = OS.get_user_data_dir() + "/out_" + timestamp + ".txt"
	var exit_path = OS.get_user_data_dir() + "/exit_" + timestamp + ".txt"

	# write the batch file
	var batch_content = "@echo off\n"
	batch_content += "cd /d \"" + working_dir + "\"\n"
	batch_content += command + " > \"" + output_path + "\" 2>&1\n"
	batch_content += "echo %ERRORLEVEL% > \"" + exit_path + "\"\n"

	var batch_file = FileAccess.open(batch_path, FileAccess.WRITE)
	batch_file.store_string(batch_content)
	batch_file.close()

	# run the batch file without blocking
	OS.create_process("cmd.exe", ["/c", batch_path])

	# wait for the exit code file to appear (means command is done)
	while not FileAccess.file_exists(exit_path):
		await Engine.get_main_loop().process_frame

	# small extra wait to make sure file writing is complete
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
	DirAccess.remove_absolute(batch_path)
	DirAccess.remove_absolute(output_path)
	DirAccess.remove_absolute(exit_path)

	return { "output": output, "exit_code": exit_code }
