class_name FileUtils

static func load_icon(icon_name: String) -> Texture2D:
	# Handle different icon path formats
	var possible_paths = [
		icon_name,  # Absolute path
		"/usr/share/icons/hicolor/48x48/apps/" + icon_name + ".png",
		"/usr/share/pixmaps/" + icon_name + ".png",
		"/usr/share/icons/hicolor/scalable/apps/" + icon_name + ".svg"
	]
	
	for path in possible_paths:
		# current path for my ubuntu install location but ccan be changed later for runing directly on linux
		var wsl_path = path.replace("/", "\\") 
		if FileAccess.file_exists(wsl_path):
			var image = Image.load_from_file(wsl_path)
			if image:
				return ImageTexture.create_from_image(image)
	
	return null  # Return null if no icon found
	
	
static var icon_for_later = "" # TODO: (refactor) remove global variable
static func parse_desktop_file(file_path: String) -> Dictionary:
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
	
	
static func get_all_file_paths(folder_path: String) -> Array:
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
