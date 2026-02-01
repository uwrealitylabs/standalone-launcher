extends Node

@onready var search_bar = $MarginContainer/VBoxContainer/LineEdit
@onready var scroll_container = $MarginContainer/VBoxContainer/ScrollContainer
@onready var apps_list = $MarginContainer/VBoxContainer/ScrollContainer/VBoxContainer

var all_apps = {}

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
	var all_files = get_all_file_paths("\\usr\\share\\applications")
	for file_path in all_files:
		if file_path != "\\\\wsl$\\Ubuntu\\usr\\share\\applications\\byobu.desktop": # this was for testing on my device as byobu.desktop wasn't readable
			var desktop_data = parse_desktop_file(file_path)
			for app_name in desktop_data:
				all_apps[app_name] = desktop_data[app_name]
	
	# UI Initilzation
	search_bar.placeholder_text = "Search applications..."
	search_bar.text_changed.connect(_on_search_changed)
	
	# Add apps to UI
	populate_apps(all_apps)

func populate_apps(apps_to_show: Dictionary):
	# Clear existing content
	for child in apps_list.get_children():
		child.queue_free()
	
	# Sort apps alphabetically
	var sorted_apps = apps_to_show.keys()
	sorted_apps.sort()
	
	# Create list item for each app
	for app_name in sorted_apps:
		var app_data = apps_to_show[app_name]
		var app_item = create_app_list_item(app_name, app_data)
		apps_list.add_child(app_item)

func create_app_list_item(app_name: String, app_data: Dictionary) -> PanelContainer:
	# panel container as a background
	var panel = PanelContainer.new()
	panel.custom_minimum_size = Vector2(1000, 60)  
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	
	# Main horizontal container
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 15)
	panel.add_child(hbox)
	
	# spacer
	var left_spacer = Control.new()
	left_spacer.custom_minimum_size.x = 20
	hbox.add_child(left_spacer)
	
	# Icon on the left of the panel
	var icon_rect = TextureRect.new()
	icon_rect.custom_minimum_size = Vector2(48, 48)
	icon_rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	
	# try and load icons
	if app_data.has("Icon"):
		var icon_texture = load_icon(app_data["Icon"])
		if icon_texture:
			icon_rect.texture = icon_texture
			
	# add icon
	hbox.add_child(icon_rect)
	
	# Vertical box for app name and categories
	var vbox = VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 5)
	hbox.add_child(vbox)
	
	# add app name
	var name_label = Label.new()
	name_label.text = app_name
	name_label.add_theme_font_size_override("font_size", 18)
	vbox.add_child(name_label)
	
	# add categories text
	if app_data.has("Categories"):
		var categories_label = Label.new()
		var categories_text = app_data["Categories"].replace(";", ", ").trim_suffix(", ")
		categories_label.text = categories_text
		categories_label.add_theme_font_size_override("font_size", 12)
		categories_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		vbox.add_child(categories_label)
		
		# spacer
		var right_spacer = Control.new()
		right_spacer.custom_minimum_size.x = 20
		hbox.add_child(right_spacer)
	
	# Make the whole panel clickable
	var button = Button.new()
	button.flat = true  # make an Invisible button over the panel
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.size_flags_vertical = Control.SIZE_EXPAND_FILL
	button.pressed.connect(_on_app_button_pressed.bind(app_data))
	
	# Add the button as an overlay
	panel.add_child(button)
	
	return panel

func load_icon(icon_name: String) -> Texture2D:
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

func _on_app_button_pressed(app_data: Dictionary):
	if app_data.has("Exec"):
		var exec_command = app_data["Exec"]
		# Clean up the exec command (remove %U, %F, etc.)
		exec_command = exec_command.replace("%U", "").replace("%F", "").replace("%u", "").replace("%f", "").strip_edges()
		
		# Launch the application
		OS.execute("wsl", ["-e", exec_command], [], false)
		print("Launching: ", exec_command)

func _on_search_changed(new_text: String):
	if new_text == "":
		populate_apps(all_apps)
	else:
		var filtered_apps = {}
		for app_name in all_apps:
			if app_name.to_lower().contains(new_text.to_lower()):
				filtered_apps[app_name] = all_apps[app_name]
		populate_apps(filtered_apps)
