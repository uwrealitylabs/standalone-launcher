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
		if FileAccess.file_exists(path):
			var image = Image.load_from_file(path)
			if image:
				return ImageTexture.create_from_image(image)
	
	return null  # Return null if no icon found
	
	
static var icon_for_later = "" # TODO: (refactor) remove global variable


## Parses the [Desktop Entry] section of the .desktop file at `file_path`.
##
## Returns { app_name: { "Exec"/"Icon"/"Categories": value } }, or an empty
## dictionary when the file cannot be read or the entry asks not to be shown.
static func parse_desktop_file(file_path: String) -> Dictionary:
	var file = FileAccess.open(file_path, FileAccess.READ)
	# A single unreadable entry must not take down the whole scan: /usr/share/
	# applications is world-readable by convention, not by guarantee.
	if file == null:
		push_warning("FileUtils: could not read %s (error %d)"
				% [file_path, FileAccess.get_open_error()])
		return {}

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


# Every field code the Desktop Entry spec defines. Anything else makes the
# command line invalid rather than literal text.
const _KNOWN_FIELD_CODES := ["f", "F", "u", "U", "d", "D", "n", "N",
		"i", "c", "k", "v", "m"]

# Codes that expand to nothing here: the launcher opens no document (%f %F %u
# %U), the code is deprecated and carries no value (%d %D %n %N %v %m), or the
# value is not tracked — %k is the .desktop file's own location, which
# parse_desktop_file does not carry through.
const _EMPTY_FIELD_CODES := ["f", "F", "u", "U", "d", "D", "n", "N", "v", "m", "k"]

# The spec confines these to an argument of their own, because each expands to
# a number of arguments rather than to text: %F and %U to one per document, %i
# to two. Embedded, they would leave a truncated argument like "--files=".
const _STANDALONE_FIELD_CODES := ["F", "U", "i"]


## Splits a .desktop `Exec` value into an argument vector, element 0 being the
## executable. Quoted arguments are unwrapped and field codes resolved: `%i`
## becomes `--icon <icon_name>` when `icon_name` is set, `%c` becomes
## `display_name`, `%%` a literal `%`, and the rest expand to nothing.
##
## Returns an empty array when the value holds no executable, and likewise when
## it is malformed — an unclosed quote, an unknown field code, or one of `%F`,
## `%U` and `%i` embedded in a larger argument — after pushing a warning naming
## the fault.
static func parse_exec(exec_value: String, display_name: String = "",
		icon_name: String = "") -> PackedStringArray:
	var tokens := _tokenize_exec(exec_value)
	# Validated up front and as a whole: the spec requires a command line
	# carrying an unusable field code to be left unprocessed, not launched with
	# the offending argument patched up or dropped.
	for token in tokens:
		var problem := _validate_token(token)
		if not problem.is_empty():
			push_warning("FileUtils: %s in Exec=%s" % [problem, exec_value])
			return PackedStringArray()

	var args := PackedStringArray()
	for token in tokens:
		# %i is the one surviving code expanding to two arguments, so it cannot
		# go through the in-token substitution below.
		if token == "%i":
			if not icon_name.is_empty():
				args.append("--icon")
				args.append(icon_name)
			continue
		var expanded := _expand_field_codes(token, display_name)
		# A token that was only a field code disappears entirely; an argument
		# the author wrote as "" is kept.
		if expanded.is_empty() and not token.is_empty():
			continue
		args.append(expanded)
	return args


## Returns "" when `token` is a usable argument, otherwise a phrase naming the
## first fault in it, suitable for embedding in a warning.
static func _validate_token(token: String) -> String:
	var i := 0
	while i < token.length():
		if token[i] != "%":
			i += 1
			continue
		# A "%" at the very end introduces no field code, so it stays literal
		# text rather than invalidating an otherwise launchable command line.
		if i + 1 >= token.length():
			break
		var code := token[i + 1]
		i += 2
		if code == "%":
			continue
		if not _KNOWN_FIELD_CODES.has(code):
			return "unknown field code %%%s" % code
		if _STANDALONE_FIELD_CODES.has(code) and token != "%" + code:
			return "%%%s used inside the argument %s" % [code, token]
	return ""


## Splits `value` on unquoted whitespace, honouring double quotes and the
## backslash escapes the spec permits inside them. Returns an empty array, and
## pushes a warning, when a quote is never closed.
static func _tokenize_exec(value: String) -> PackedStringArray:
	var tokens := PackedStringArray()
	var current := ""
	# Tracked separately from `current`, which stays empty for a quoted ""
	var has_token := false
	var in_quotes := false
	var i := 0

	while i < value.length():
		var c := value[i]
		if in_quotes:
			if c == "\\" and i + 1 < value.length() \
					and value[i + 1] in ["\"", "`", "$", "\\"]:
				current += value[i + 1]
				i += 2
			elif c == "\"":
				in_quotes = false
				i += 1
			else:
				current += c
				i += 1
		elif c == "\"":
			in_quotes = true
			has_token = true
			i += 1
		elif c == " " or c == "\t":
			if has_token:
				tokens.append(current)
				current = ""
				has_token = false
			i += 1
		else:
			current += c
			has_token = true
			i += 1

	# Recovering here would only be a guess, and the guess falls on argument
	# boundaries: "a b would silently become one argument instead of two.
	if in_quotes:
		push_warning("FileUtils: unclosed quote in Exec=%s" % value)
		return PackedStringArray()

	if has_token:
		tokens.append(current)
	return tokens


## Resolves the field codes inside a single token.
static func _expand_field_codes(token: String, display_name: String) -> String:
	var out := ""
	var i := 0

	while i < token.length():
		if token[i] != "%" or i + 1 >= token.length():
			out += token[i]
			i += 1
			continue
		var code := token[i + 1]
		i += 2
		if code == "%":
			out += "%"
		elif code == "c":
			out += display_name
		# Anything still here is a code that expands to nothing; _validate_token
		# has already turned back the codes with no expansion at all.

	return out


static func get_all_file_paths(folder_path: String) -> Array:
	var files = []
	var dir = DirAccess.open(folder_path)

	if dir == null:
		printerr("Could not open directory: ", folder_path)
		return files

	dir.list_dir_begin()
	var file_name = dir.get_next()

	while file_name != "":
		# Must be "/": FileAccess normalizes a "\" separator but DirAccess does
		# not, so a backslash here silently skips every subdirectory.
		var full_path = folder_path + "/" + file_name

		if dir.current_is_dir():
			var sub_files = get_all_file_paths(full_path)
			files.append_array(sub_files)
		else:
			files.append(full_path)

		file_name = dir.get_next()

	dir.list_dir_end()
	return files
