extends SceneTree

## Verifies the compositor GDExtension is registered where a library exists for
## the host, and is cleanly absent where none does.
##
## The absent case is a real assertion, not a skip. The descriptor advertises
## Linux arm64 only, so on macOS and x86_64 CI the class must NOT appear -- if it
## ever did, the descriptor would be claiming a platform nothing builds for.
##
## Godot registers extensions during project import, so a run that has not
## imported first reports the class missing everywhere and proves nothing. Run:
##   godot --headless --xr-mode off --path . --import
##   godot --headless --xr-mode off --path . \
##       --script res://tests/compositor_extension_check.gd

const Report := preload("res://tests/support/report.gd")

const CLASS_NAME := "WaylandCompositor"
const DESCRIPTOR := "res://project/compositor/wayland_compositor.linux_arm64_only.gdextension"

# Emitted by WaylandCompositor. Ordered as the lifecycle reaches them.
const EXPECTED_SIGNALS := [
	"surface_mapped",
	"surface_resized",
	"surface_unmapped",
	"frame_available",
	"client_gone",
]


func _init() -> void:
	var report := Report.new()

	var host := "%s %s" % [OS.get_name(), Engine.get_architecture_name()]
	var library := _library_for_host()

	report.section("host: %s" % host)
	report.check("descriptor is readable", library.has("parsed"), library.get("error", ""))
	if not library.has("parsed"):
		report.finish(self)
		return

	var expected: bool = library["exists"]
	report.check("library present for this host: %s" % str(expected), true,
			library["path"] if library["path"] != "" else "no entry for this host")

	report.section("class registration")
	var registered := ClassDB.class_exists(CLASS_NAME)
	report.check("ClassDB.class_exists(%s) == %s" % [CLASS_NAME, str(expected)],
			registered == expected)

	if not registered:
		# Nothing further is checkable, and on a non-target host that is the
		# correct outcome rather than a gap in coverage.
		report.finish(self)
		return

	report.section("registered class shape")
	report.check("derives from Node", ClassDB.get_parent_class(CLASS_NAME) == "Node")

	var instance: Object = ClassDB.instantiate(CLASS_NAME)
	report.check("instantiates", instance != null)
	if instance == null:
		report.finish(self)
		return

	for signal_name in EXPECTED_SIGNALS:
		report.check("has signal %s" % signal_name, instance.has_signal(signal_name))
	report.check("has get_stats()", instance.has_method("get_stats"))
	report.check("has get_texture()", instance.has_method("get_texture"))
	report.check("no texture before a frame arrives", instance.get_texture() == null)

	# Never entered a tree, so _ready never ran and no server was started; free
	# is enough and there is nothing to shut down.
	instance.free()

	report.finish(self)


## Reads the descriptor and reports whether a library is built for this host.
## Returns a dictionary with "parsed", "path" and "exists", or "error".
func _library_for_host() -> Dictionary:
	var config := ConfigFile.new()
	var err := config.load(DESCRIPTOR)
	if err != OK:
		return {"error": "ConfigFile.load returned %d" % err}

	# Godot picks a library by matching every dot-separated tag in the key
	# against the host's feature tags, so the same matching is redone here
	# rather than hardcoding a platform name.
	for key in config.get_section_keys("libraries"):
		var matched := true
		for tag in key.split("."):
			if not OS.has_feature(tag):
				matched = false
				break
		if matched:
			var path: String = config.get_value("libraries", key)
			return {
				"parsed": true,
				"path": path,
				"exists": FileAccess.file_exists(path),
			}

	return {"parsed": true, "path": "", "exists": false}
