extends Node

func parse_desktop_file(file_path: String) -> Dictionary:
	var file = FileAccess.open(file_path, FileAccess.READ)

	var apps = {}
	var current_section = ""

	while not file.eof_reached():
		var line = file.get_line().strip_edges()
		if line.begins_with("Name="):
			current_section = (line.split("Name="))[1]
			apps[current_section] = {}
		elif line.contains("="):
			var parts = line.split("=", 2)
			var key = parts[0].strip_edges()
			if key == "Terminal":
				var value = parts[1].strip_edges()
				if value == "false":
					continue
				else:
					return {}
			if key == "NoDisplay":
				var value = parts[1].strip_edges()
				if value == "false":
					continue
				else:
					return {}
			if key == "Exec" or key == "Icon" or key == "Categories":
				var value = parts[1].strip_edges()
				if current_section:
					apps[current_section][key] = value
				else:
					apps[key] = value

	file.close()
	return apps
	
func get_all_file_paths(folder_path: String) -> Array:
	var files = []
	var dir = DirAccess.open(folder_path)

	if dir == null:
		printerr("Could not open directory: ", folder_path)
		return files

	dir.list_dir_begin()
	var file_name = dir.get_next()

	while file_name != "":
		var full_path = folder_path + "\\" + file_name

		if dir.current_is_dir():
			var sub_files = get_all_file_paths(full_path)
			files.append_array(sub_files)
		else:
			files.append(full_path)

		file_name = dir.get_next()

	dir.list_dir_end()
	return files
	
func _ready():
	var all_files = get_all_file_paths("\\\\wsl$\\Ubuntu\\usr\\share\\applications")
	for file_path in all_files:
		if file_path != "\\\\wsl$\\Ubuntu\\usr\\share\\applications\\byobu.desktop":
			var desktop_data = parse_desktop_file(file_path)
			print(desktop_data)
		
