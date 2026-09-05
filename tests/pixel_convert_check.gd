extends SceneTree

## Compiles and runs native/tests/test_pixel_convert.c, the unit tests for the
## compositor bridge's pixel conversion.
##
## Run with:
##   godot --headless --xr-mode off --path . \
##       --script res://tests/pixel_convert_check.gd
##
## The conversion lives in a translation unit that pulls in neither wlroots nor
## godot-cpp, so this suite is the pixel path's only coverage that runs on a
## development Mac and on the x86_64 CI runner as well as on the arm64 target.
## Everything else in the native path needs the built GDExtension.
##
## A host with no C compiler reports a skip rather than a failure: the suite
## cannot tell "compiler absent" apart from "toolchain broken", and failing the
## whole run on the former would be a false alarm.

const Report := preload("res://tests/support/report.gd")

## Printed verbatim by native/tests/test_pixel_convert.c when every check passed.
const NATIVE_SUCCESS_LINE := "PASS - all checks passed"

var _report := Report.new()


func _initialize() -> void:
	_report.section("pixel conversion (native)")

	var compiler := _find_compiler()
	if compiler.is_empty():
		# Not a failure: see the note in the class docs above.
		print("  skip no C compiler on PATH (cc, clang or gcc)")
		_report.finish(self)
		return

	var binary := OS.get_user_data_dir() + "/test_pixel_convert"
	var sources := [
		ProjectSettings.globalize_path("res://native/tests/test_pixel_convert.c"),
		ProjectSettings.globalize_path("res://native/bridge/pixel_convert.c"),
	]

	for source in sources:
		if not FileAccess.file_exists(source):
			_report.check("source present: " + source.get_file(), false, "missing")
			_report.finish(self)
			return

	var compile_args := ["-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
			"-o", binary]
	compile_args.append_array(sources)

	var output := []
	var compile_code := OS.execute(compiler, compile_args, output, true)
	# -Werror is deliberate: a warning in this unit is a defect in the pixel
	# path, and the CI runner's compiler is not the one used during development.
	_report.check("compiles clean under -Werror", compile_code == 0,
			"\n".join(PackedStringArray(output)))
	if compile_code != 0:
		_report.finish(self)
		return

	output.clear()
	var run_code := OS.execute(binary, [], output, true)
	var text := "\n".join(PackedStringArray(output))

	# Relay the native output so a failing check names itself in this log too,
	# rather than only reporting that some check failed.
	for line in text.split("\n", false):
		print("  | ", line)

	_report.check("native suite exits zero", run_code == 0, str(run_code))
	# Checked as well as the exit code: a suite that dies part-way can still
	# exit 0, which is the same trap tests/support/report.gd guards against.
	_report.check("native suite ran to completion",
			text.contains(NATIVE_SUCCESS_LINE), "success line absent")

	DirAccess.remove_absolute(binary)
	_report.finish(self)


## First C compiler found on PATH, or "" when the host has none.
func _find_compiler() -> String:
	for name in ["cc", "clang", "gcc"]:
		var output := []
		if OS.execute("which", [name], output, true) == 0:
			var path := "\n".join(PackedStringArray(output)).strip_edges()
			if not path.is_empty():
				return path
	return ""
