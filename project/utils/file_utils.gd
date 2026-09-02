class_name FileUtils

## Environment variable naming the directory to scan instead of the default.
const SHARE_DIR_ENV := "WRL_SHARE_DIR"

## Where the target board keeps its applications and icons.
const DEFAULT_SHARE_DIR := "/usr/share"


## Root of the applications/, icons/ and pixmaps/ trees the launcher reads.
##
## Returns [constant DEFAULT_SHARE_DIR] unless [constant SHARE_DIR_ENV] names
## another directory, in which case that one is used with trailing slashes
## removed.
static func share_dir() -> String:
	var override := OS.get_environment(SHARE_DIR_ENV)
	if override.is_empty():
		return DEFAULT_SHARE_DIR
	return override.rstrip("/")


## Directory holding the .desktop files to scan.
static func applications_dir() -> String:
	return share_dir() + "/applications"


## Parses the [Desktop Entry] section of the .desktop file at `file_path`.
##
##     Name=Files
##     Exec=nautilus %U     ->  { "Files": { "Exec": "nautilus %U",
##     Icon=folder                            "Icon": "folder" } }
##
## Keys may appear in any order. Returns an empty dictionary when the file
## cannot be read, carries no Name, or sets Terminal or NoDisplay.
static func parse_desktop_file(file_path: String) -> Dictionary[String, Dictionary]:
	var result: Dictionary[String, Dictionary] = {}
	var file := FileAccess.open(file_path, FileAccess.READ)
	# A single unreadable entry must not take down the whole scan: /usr/share/
	# applications is world-readable by convention, not by guarantee.
	if file == null:
		push_warning("FileUtils: could not read %s (error %d)"
				% [file_path, FileAccess.get_open_error()])
		return result

	var in_desktop_entry := false
	var entry_name := ""
	# Keys land here as they are read and the entry is named at the end, because
	# Name may come last: the spec fixes no order, and a file whose keys are
	# sorted puts Categories, Exec and Icon ahead of it.
	var entry := {}

	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		if line.begins_with("#"):
			continue

		if line.begins_with("[") and line.ends_with("]"):
			# [Desktop Entry] is the only section read; the next header ends it.
			if in_desktop_entry:
				break
			in_desktop_entry = line == "[Desktop Entry]"
			continue
		if not in_desktop_entry or not line.contains("="):
			continue

		# Cut into key and value at the first "=" only, so the value keeps any
		# further ones: "Exec=env FOO=1 app" gives "env FOO=1 app".
		var parts := line.split("=", true, 1)
		var key := parts[0].strip_edges()
		# Whitespace comes off first, escapes second: "\s" is how the format
		# writes a space that the trim would otherwise have eaten.
		var value := _unescape_value(parts[1].strip_edges())

		if key == "Terminal" or key == "NoDisplay":
			# Anything but an explicit "false" is read as asking to be hidden.
			if value != "false":
				return result
		elif key == "Name":
			entry_name = value
		elif key == "Exec" or key == "Icon" or key == "Categories":
			entry[key] = value

	file.close()
	# The Name is the entry's key, so an entry without one cannot be returned.
	if entry_name.is_empty():
		return result
	result[entry_name] = entry
	return result


## Decodes the escapes the .desktop format defines for every string value. Runs
## before any key-specific rule, such as the quoting inside an Exec value.
##
##     /opt/My\sApps  ->  /opt/My Apps
##     a\\b           ->  a\b
##     C:\Program     ->  C:\Program     (\P is not an escape, so it stays)
##
## The defined escapes are \s \n \t \r and \\; the spec leaves any other
## backslash pair undefined.
static func _unescape_value(raw: String) -> String:
	var out := ""
	var i := 0

	while i < raw.length():
		if raw[i] != "\\" or i + 1 >= raw.length():
			out += raw[i]
			i += 1
			continue
		match raw[i + 1]:
			"s": out += " "
			"n": out += "\n"
			"t": out += "\t"
			"r": out += "\r"
			"\\": out += "\\"
			# Undefined pairs keep their backslash. Wine writes Windows paths
			# such as C:\Program\app.exe, and dropping it would break them.
			_: out += "\\" + raw[i + 1]
		i += 2

	return out


## Splits a list value such as Categories on its ";" separators.
##
##     Utility;Development;   ->  ["Utility", "Development"]
##     Utility;Audio\;Video;  ->  ["Utility", "Audio;Video"]
##
## A ";" that belongs inside an element is written "\;" and does not separate.
## The trailing separator the spec asks for adds no empty final element.
static func split_list_value(value: String) -> PackedStringArray:
	var items := PackedStringArray()
	var current := ""
	var i := 0

	while i < value.length():
		if value[i] == "\\" and i + 1 < value.length() and value[i + 1] == ";":
			current += ";"
			i += 2
		elif value[i] == ";":
			items.append(current)
			current = ""
			i += 1
		else:
			current += value[i]
			i += 1

	if not current.is_empty():
		items.append(current)
	return items


# Every field code the Desktop Entry spec defines. Anything else makes the
# command line invalid rather than literal text.
const _KNOWN_FIELD_CODES := ["f", "F", "u", "U", "d", "D", "n", "N",
		"i", "c", "k", "v", "m"]

# Codes that expand to nothing here: %f %F %u %U name the documents being
# opened, and this launcher opens none; %d %D %n %N %v %m are deprecated; %k is
# the .desktop file's own path, which parsing does not carry through.
const _EMPTY_FIELD_CODES := ["f", "F", "u", "U", "d", "D", "n", "N", "v", "m", "k"]

# Codes the spec allows only as a whole argument, because each stands for a
# number of arguments rather than for text: %F and %U for one per document, %i
# for two. Written inside a larger argument they leave a stub like "--files=".
const _STANDALONE_FIELD_CODES := ["F", "U", "i"]


## Splits a .desktop `Exec` value into an argument vector, element 0 being the
## executable.
##
##     firefox %U             ->  ["firefox"]
##     sh -c "echo hi there"  ->  ["sh", "-c", "echo hi there"]
##     app %i                 ->  ["app", "--icon", "folder"]
##
## Quotes are unwrapped and field codes resolved: `%i` becomes
## `--icon <icon_name>` when `icon_name` is set, `%c` becomes `display_name`,
## `%%` a literal `%`, and the rest expand to nothing.
##
## Returns an empty array when the value holds no executable, and likewise when
## it is malformed — an unclosed quote, an unknown field code, or one of `%F`,
## `%U` and `%i` written inside a larger argument — after pushing a warning
## naming the fault.
static func parse_exec(exec_value: String, display_name: String = "",
		icon_name: String = "") -> PackedStringArray:
	var tokens := _tokenize_exec(exec_value)
	# Every token is checked before any is expanded, because one bad field code
	# invalidates the whole command line: the spec asks for it to be left alone
	# rather than launched with the offending argument dropped or patched.
	for token in tokens:
		var problem := _validate_token(token)
		if not problem.is_empty():
			push_warning("FileUtils: %s in Exec=%s" % [problem, exec_value])
			return PackedStringArray()

	var args := PackedStringArray()
	for token in tokens:
		# %i becomes two arguments, so it is handled here instead of by the
		# substitution below, which can only give one back.
		if token == "%i":
			if not icon_name.is_empty():
				args.append("--icon")
				args.append(icon_name)
			continue
		var expanded := _expand_field_codes(token, display_name)
		# Dropped when a field code expanded away to nothing. An argument the
		# author wrote as "" starts out empty, so it survives this.
		if expanded.is_empty() and not token.is_empty():
			continue
		args.append(expanded)
	return args


## Returns "" when `token` is a usable argument, otherwise a phrase naming the
## first fault in it, ready to drop into a warning.
##
##     --tab       ->  ""
##     %x          ->  "unknown field code %x"
##     --files=%F  ->  "%F used inside the argument --files=%F"
static func _validate_token(token: String) -> String:
	var i := 0
	while i < token.length():
		if token[i] != "%":
			i += 1
			continue
		# A trailing "%" has no code after it to be wrong about, so it counts as
		# literal text rather than as a reason to reject the command line.
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


## Splits `value` on whitespace that falls outside double quotes.
##
##     sh -c "echo hi"    ->  ["sh", "-c", "echo hi"]
##     app "a \" b"       ->  ["app", 'a " b']
##     app foo"bar b"qux  ->  ["app", "foobar bqux"]
##
## Inside quotes a backslash escapes " ` $ and \. Returns an empty array, and
## pushes a warning, when a quote is never closed.
static func _tokenize_exec(value: String) -> PackedStringArray:
	var tokens := PackedStringArray()
	var current := ""
	# Set by the first character or quote seen, so that an argument written as
	# "" is still emitted even though `current` stays empty.
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

	# Give up rather than guess: with the closing quote missing there is no way
	# to tell where the argument ended, and guessing wrong silently welds two
	# arguments into one.
	if in_quotes:
		push_warning("FileUtils: unclosed quote in Exec=%s" % value)
		return PackedStringArray()

	if has_token:
		tokens.append(current)
	return tokens


## Resolves the field codes inside a single token, given the entry's
## `display_name` for `%c`.
##
##     --tab       ->  --tab
##     100%%       ->  100%
##     %c          ->  the display name
##     --file=%f   ->  --file=      (there is no document to name)
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
		# Every other code expands to nothing. The ones that may not appear in a
		# larger argument were already turned back by validation.

	return out


static func get_all_file_paths(folder_path: String) -> Array:
	var files = []
	var dir = DirAccess.open(folder_path)

	if dir == null:
		# A missing directory is expected off the board; only an unopenable one is an error.
		if not DirAccess.dir_exists_absolute(folder_path):
			print("FileUtils: %s does not exist; skipping it. Expected off Linux."
					% folder_path)
		else:
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
