extends SceneTree

## Verifies FileUtils' .desktop parsing and directory walking against fixtures
## written to user:// at run time. Run with:
##   godot --headless --xr-mode off --script res://tests/file_utils_check.gd
##
## The unreadable-file and malformed-Exec checks deliberately trigger
## push_warning; those warnings in the log are expected output, not failures.

var _fixture_dir := ""
var _failures := 0


func _initialize() -> void:
	_fixture_dir = OS.get_user_data_dir() + "/file_utils_check"
	_teardown()  # a previous aborted run may have left the directory behind
	DirAccess.make_dir_recursive_absolute(_fixture_dir + "/nested")

	_check_unreadable_file_is_survivable()
	_check_entry_fields_parsed()
	_check_hidden_entries_skipped()
	_check_directory_walk()
	_check_key_order_independent()
	_check_value_decoding()
	_check_exec_parsing()

	_teardown()

	print("")
	if _failures == 0:
		print("PASS - all checks passed")
		quit(0)
	else:
		print("FAIL - %d check(s) failed" % _failures)
		quit(1)


## A file that cannot be opened must yield an empty dictionary, not a crash.
func _check_unreadable_file_is_survivable() -> void:
	print("[unreadable file]")
	var missing := _fixture_dir + "/does_not_exist.desktop"
	var parsed := FileUtils.parse_desktop_file(missing)
	_check("missing file returns an empty dictionary", parsed.is_empty(), str(parsed))


## Name keys the result; Exec, Icon and Categories are carried through.
func _check_entry_fields_parsed() -> void:
	print("[entry fields]")
	var path := _write_fixture("valid.desktop", [
		"[Desktop Entry]",
		"Type=Application",
		"Name=Test App",
		"Exec=/bin/echo hello",
		"Icon=test-icon",
		"Categories=Utility;Development;",
		"Terminal=false",
		"NoDisplay=false",
	])
	var parsed := FileUtils.parse_desktop_file(path)
	_check("entry is keyed by Name", parsed.has("Test App"), str(parsed.keys()))
	if not parsed.has("Test App"):
		return
	var app: Dictionary = parsed["Test App"]
	_check("Exec parsed", app.get("Exec", "") == "/bin/echo hello", str(app.get("Exec", "")))
	_check("Icon parsed", app.get("Icon", "") == "test-icon", str(app.get("Icon", "")))
	_check("Categories parsed", app.get("Categories", "") == "Utility;Development;",
			str(app.get("Categories", "")))


## Terminal=true and NoDisplay=true entries are not offered to the launcher.
func _check_hidden_entries_skipped() -> void:
	print("[hidden entries]")
	var terminal := _write_fixture("terminal.desktop", [
		"[Desktop Entry]",
		"Name=Terminal App",
		"Exec=/bin/echo hi",
		"Terminal=true",
	])
	_check("Terminal=true entry is skipped",
			FileUtils.parse_desktop_file(terminal).is_empty())

	var hidden := _write_fixture("hidden.desktop", [
		"[Desktop Entry]",
		"Name=Hidden App",
		"Exec=/bin/echo hi",
		"NoDisplay=true",
	])
	_check("NoDisplay=true entry is skipped",
			FileUtils.parse_desktop_file(hidden).is_empty())


## The walk must recurse into subdirectories and return paths that are openable
## as-is. Both hang on the separator: FileAccess normalizes a "\" but DirAccess
## does not, so a wrong separator loses whole subtrees while still looking fine
## on the files it did find.
func _check_directory_walk() -> void:
	print("[directory walk]")
	_write_fixture("nested/deep.desktop", ["[Desktop Entry]", "Name=Deep App"])
	var found := FileUtils.get_all_file_paths(_fixture_dir)
	_check("walk finds all 4 fixture files", found.size() == 4, str(found.size()))
	var all_readable := true
	for path in found:
		if not FileAccess.file_exists(path):
			all_readable = false
			print("    unreadable: ", path)
	_check("every returned path is readable as returned", all_readable)


## The spec fixes no key order, so an entry whose keys are sorted puts Exec,
## Icon and Categories ahead of Name and all of them must still land.
func _check_key_order_independent() -> void:
	print("[key order]")
	var path := _write_fixture("alpha.desktop", [
		"[Desktop Entry]",
		"Categories=Utility;",
		"Exec=/usr/bin/alpha %U",
		"Icon=alpha-icon",
		"Name=Alpha",
		"Type=Application",
	])
	var app: Dictionary = FileUtils.parse_desktop_file(path).get("Alpha", {})
	_check("Exec survives ahead of Name",
			app.get("Exec", "") == "/usr/bin/alpha %U", str(app))
	_check("Categories survives ahead of Name",
			app.get("Categories", "") == "Utility;", str(app))
	_check("Icon survives ahead of Name", app.get("Icon", "") == "alpha-icon", str(app))

	# An Icon read before any Name used to be parked in a static and handed to
	# whichever file happened to be parsed next.
	var bare := _write_fixture("bare.desktop", [
		"[Desktop Entry]", "Name=Bare", "Exec=/bin/bare",
	])
	var bare_app: Dictionary = FileUtils.parse_desktop_file(bare).get("Bare", {})
	_check("no icon leaks in from the previous file", not bare_app.has("Icon"),
			str(bare_app))

	var unnamed := _write_fixture("unnamed.desktop", [
		"[Desktop Entry]", "Name=", "Exec=/bin/foo", "Icon=ico",
	])
	_check("an empty Name yields no entry",
			FileUtils.parse_desktop_file(unnamed).is_empty())


## Values carry their own "=", and are unescaped before any key-specific rule.
func _check_value_decoding() -> void:
	print("[value decoding]")
	var path := _write_fixture("escapes.desktop", [
		"[Desktop Entry]",
		"Name=Escapes",
		"Exec=env FOO=1 /bin/app --tab=new",
		"Icon=a\\sb",
		"Categories=Utility;Audio\\;Video;",
	])
	var app: Dictionary = FileUtils.parse_desktop_file(path).get("Escapes", {})
	_check("a value keeps everything past its first =",
			app.get("Exec", "") == "env FOO=1 /bin/app --tab=new",
			str(app.get("Exec", "")))
	_check("\\s decodes to a space", app.get("Icon", "") == "a b",
			str(app.get("Icon", "")))
	var cats := FileUtils.split_list_value(app.get("Categories", ""))
	_check("an escaped ; stays inside its element",
			cats == PackedStringArray(["Utility", "Audio;Video"]), str(cats))

	# Wine writes Windows paths into Exec, and none of those backslashes are
	# escapes the spec defines.
	var wine := _write_fixture("wine.desktop", [
		"[Desktop Entry]", "Name=Wine", "Exec=wine C:\\Program\\app.exe",
	])
	var wine_app: Dictionary = FileUtils.parse_desktop_file(wine).get("Wine", {})
	_check("an unrecognized escape is left alone",
			wine_app.get("Exec", "") == "wine C:\\Program\\app.exe",
			str(wine_app.get("Exec", "")))


## Exec values must reach OS.create_process as a real argument vector: the
## executable alone in element 0, arguments split off, and field codes gone.
func _check_exec_parsing() -> void:
	print("[exec parsing]")
	_check_exec("firefox", ["firefox"])
	_check_exec("/usr/bin/gnome-terminal --window", ["/usr/bin/gnome-terminal", "--window"])
	_check_exec("   spaced   out  ", ["spaced", "out"])
	_check_exec("env FOO=1 /bin/app", ["env", "FOO=1", "/bin/app"])

	# Field codes expand to nothing without a document to open, and must not
	# survive as empty arguments.
	_check_exec("firefox %U", ["firefox"])
	_check_exec("app %f %F %u %U %d %D %n %N %v %m %k", ["app"])
	_check_exec("app --tab %U --new", ["app", "--tab", "--new"])

	# Quoting groups an argument; %% is a literal percent.
	_check_exec('sh -c "echo hi there"', ["sh", "-c", "echo hi there"])
	_check_exec('app "/opt/My Apps/run.sh"', ["app", "/opt/My Apps/run.sh"])
	_check_exec("app\tone\ttwo", ["app", "one", "two"])
	_check_exec('app foo"bar baz"qux', ["app", "foobar bazqux"])
	# An argument the author wrote as "" survives as an empty argument, where a
	# field code that expanded to nothing would have been dropped.
	_check_exec('app "" x', ["app", "", "x"])
	_check_exec("app 100%%", ["app", "100%"])

	# All four escapes the spec allows inside a quoted argument.
	_check_exec('app "a \\"quoted\\" b"', ["app", 'a "quoted" b'])
	_check_exec('app "a\\\\b"', ["app", "a\\b"])
	_check_exec('app "a\\`b"', ["app", "a`b"])
	_check_exec('app "a\\$b"', ["app", "a$b"])
	# A backslash before anything else is literal. Wine-generated entries lean on
	# this, and it is what keeps them intact once the value is unescaped upstream.
	_check_exec('app "C:\\Program\\app.exe"', ["app", "C:\\Program\\app.exe"])

	# Reserved characters are carried through untouched: the argv goes straight to
	# create_process, so nothing downstream gives them shell meaning.
	_check_exec("app a;b|c&d", ["app", "a;b|c&d"])

	# %i expands to two arguments, %c to the display name; both only when the
	# caller supplies the value.
	_check_exec("app %i", ["app", "--icon", "test-icon"], "Test App", "test-icon")
	_check_exec("app %i", ["app"], "Test App", "")
	_check_exec("app %c", ["app", "Test App"], "Test App", "")

	# %f and %u are single-valued, so the spec does allow them inside a larger
	# argument; with no document they leave the rest of the argument standing.
	_check_exec("app --file=%f", ["app", "--file="])
	_check_exec("app %k", ["app"])
	_check_exec("app 100%", ["app", "100%"])
	_check_exec("app %%F", ["app", "%F"])
	# The spec calls expansion inside a quoted argument undefined rather than
	# invalid, so expanding is one of the conformant choices; pinned here.
	_check_exec('app "%U"', ["app"])

	_check("empty Exec yields no argv", FileUtils.parse_exec("").is_empty())
	_check("field-code-only Exec yields no argv", FileUtils.parse_exec("%U").is_empty())

	_check_rejected("unknown field code", "app %x")
	_check_rejected("%F inside a larger argument", "app --files=%F")
	_check_rejected("%U inside a larger argument", "app --urls=%U")
	_check_rejected("%i inside a larger argument", "app --icon=%i")
	_check_rejected("unclosed quote", 'app "unterminated')
	_check_rejected("unclosed quote around a path", 'app "/opt/My Apps/run.sh')


## A malformed Exec must yield no argv at all: the spec leaves such a command
## line unprocessed rather than launched with the bad argument patched over.
func _check_rejected(label: String, exec_value: String) -> void:
	var got := FileUtils.parse_exec(exec_value, "Test App", "test-icon")
	_check("%s rejects Exec=%s" % [label, exec_value], got.is_empty(), str(got))


func _check_exec(exec_value: String, expected: Array, display_name: String = "",
		icon_name: String = "") -> void:
	var got := FileUtils.parse_exec(exec_value, display_name, icon_name)
	var want := PackedStringArray(expected)
	_check("Exec=%s -> %s" % [exec_value, want], got == want, str(got))


func _write_fixture(relative_path: String, lines: Array) -> String:
	var path := _fixture_dir + "/" + relative_path
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_failures += 1
		print("  FAIL could not write fixture ", path)
		return path
	file.store_string("\n".join(lines) + "\n")
	file.close()
	return path


func _teardown() -> void:
	var dir := DirAccess.open(_fixture_dir)
	if dir == null:
		return
	for sub in dir.get_directories():
		var nested := DirAccess.open(_fixture_dir + "/" + sub)
		for f in nested.get_files():
			DirAccess.remove_absolute(_fixture_dir + "/" + sub + "/" + f)
		DirAccess.remove_absolute(_fixture_dir + "/" + sub)
	for f in dir.get_files():
		DirAccess.remove_absolute(_fixture_dir + "/" + f)
	DirAccess.remove_absolute(_fixture_dir)


func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		print("  ok   ", label)
	else:
		_failures += 1
		print("  FAIL ", label, "" if detail.is_empty() else "  (got %s)" % detail)
