extends Node

var all_apps = {}
var icon_for_later = ""


func parse_desktop_file(file_path: String) -> Dictionary:
	var file = FileAccess.open(file_path, FileAccess.READ)

	var in_desktop_entry = false
	var apps = {}
	var current_section = ""

	while not file.eof_reached():
		
		
		var line = file.get_line().strip_edges()
		
		if line.begins_with("[") and line.ends_with("]"):
			if line == "[Desktop Entry]":
				in_desktop_entry = true
				continue
			if in_desktop_entry:
				break
			continue
		if in_desktop_entry == true:
			if line.begins_with("Name="):
				current_section = (line.split("Name="))[1]
				apps[current_section] = {}
				if icon_for_later != "":
					apps[current_section]["Icon"] = icon_for_later
			elif line.contains("=") and apps != {}:
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
			if apps == {}:
					var parts = line.split("=", 2)
					var key = parts[0].strip_edges()
					if key == "Icon":
						icon_for_later = parts[1].strip_edges()
				
	
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
	var all_files = get_all_file_paths("/usr/share/applications")
	for file_path in all_files:
			var desktop_data = parse_desktop_file(file_path)
			for app_name in desktop_data:
					all_apps[app_name] = desktop_data[app_name]
