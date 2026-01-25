extends Button

func open_app():
	match OS.get_name():
		"Windows":
			var pid = OS.create_process("powershell", [], true)
			if pid != 1:
				print("Process created with PID: ", pid)
			else:
				print("Failed to create process.")
		"Linux", "X11":
			var path = "weston-terminal" # in quotes place the path or application name you want launched
			var args = [] # whatever arguments you want the app to launch with
			var pid = OS.create_process(path, args, true) # final boolean is wheater you want a to open the console or not
			if pid != 1:
				print("Process created with PID: ", pid)
			else:
				print("Failed to create process.")

func _on_pressed() -> void:
	open_app()
