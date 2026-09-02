extends SceneTree

## Verifies the compositor scenes load and are authored correctly on every host,
## including hosts with no GDExtension built.
##
## That last part is the point. The Wayland extension is Linux-arm64 only, so on
## macOS and on x86_64 CI `WaylandCompositor` does not exist; the scenes must
## still load and the script must still parse, or the whole project stops
## opening in the editor for everyone who is not on the target.
##
## Three scenes are covered, because the screen is now used twice:
##   compositor_screen.tscn  the reusable quad, script and all
##   compositor_poc.tscn     the local Linux harness wrapper
##   root.tscn               the launcher, which instances the screen
##
## Instantiates without adding to a tree, so _ready never runs and the values
## checked come from the scene files rather than from runtime. That is what
## makes the visibility assertion meaningful: a quad hidden only by _ready would
## still read as visible here.
##
## Loading root.tscn pulls in the XR Tools addon, whose scripts reference
## autoload singletons that a --script run does not register. The resulting
## "Identifier not found: XRToolsUserSettings" errors are expected noise and do
## not affect the assertions below, which read the serialized scene state.
##
## Run with:
##   godot --headless --xr-mode off --path . \
##       --script res://tests/compositor_scene_check.gd

const Report := preload("res://tests/support/report.gd")

const SCREEN_SCENE := "res://project/compositor/compositor_screen.tscn"
const POC_SCENE := "res://project/compositor/compositor_poc.tscn"
const ROOT_SCENE := "res://project/main/root.tscn"
const POC_SCRIPT := "res://project/compositor/compositor_poc.gd"
const DESCRIPTOR := "res://project/compositor/wayland_compositor.linux_arm64_only.gdextension"

# The quad is authored square and re-aspected at runtime from the surface size.
const AUTHORED_QUAD_SIZE := Vector2(0.6, 0.6)

# Where the harness wrapper puts the screen: in front of the origin at roughly
# eye height, so tests/linux/ camera setups frame it without being told to.
const HARNESS_ORIGIN := Vector3(0.0, 1.2, -1.0)

# Where root.tscn puts it: beside the terminal window, which sits at x = 0.3.
const LAUNCHER_ORIGIN := Vector3(1.6, 1.5, -2.0)

# Node path get_state() reports for the launcher's instance, minus the leading
# "./" that SceneState prefixes onto every path.
const LAUNCHER_NODE_PATH := "WindowManager/CompositorScreen"


func _init() -> void:
	var report := Report.new()

	report.section("screen scene loads without the extension")
	var scene: PackedScene = load(SCREEN_SCENE)
	report.check("compositor_screen.tscn loads", scene != null)
	if scene == null:
		report.finish(self)
		return
	var screen := scene.instantiate() as MeshInstance3D
	report.check("root is a MeshInstance3D", screen != null)
	if screen == null:
		report.finish(self)
		return
	report.check("root is named CompositorScreen", screen.name == "CompositorScreen",
			str(screen.name))
	report.check("script is attached to the root",
			screen.get_script() != null
					and screen.get_script().resource_path == POC_SCRIPT)

	report.section("screen quad")
	var mesh := screen.mesh as QuadMesh
	report.check("uses a QuadMesh", mesh != null)
	if mesh != null:
		report.near("quad width", mesh.size.x, AUTHORED_QUAD_SIZE.x)
		report.near("quad height", mesh.size.y, AUTHORED_QUAD_SIZE.y)
		# _apply_aspect rewrites mesh.size at runtime. Without this the two
		# instances of the scene would share one QuadMesh and the first client
		# to map would resize the other instance's quad too.
		report.check("mesh is local to the scene", mesh.resource_local_to_scene)

	# Authored, not applied by _ready -- nothing has entered a tree here. A
	# regression that moved this back into _ready would show up as a visible
	# white quad for one frame on the board, and as a permanent one wherever
	# the script returns early.
	report.check("visibility is authored false", not screen.visible)

	report.section("no compositor node is authored into the scene")
	# The node is created at runtime only when the class exists. Authoring it
	# into the .tscn would make the scene fail to load wherever the extension
	# is not built, which is everywhere except the board and the VM.
	var authored_compositor := false
	for child in screen.get_children():
		if child.get_class() == "WaylandCompositor":
			authored_compositor = true
	report.check("scene has no WaylandCompositor node", not authored_compositor)
	screen.free()

	_check_harness_wrapper(report)
	_check_launcher_integration(report)
	_check_descriptor(report)

	report.finish(self)


## The wrapper kept for tests/linux/: a bare Node3D holding one screen instance.
## The script lives on the instance now, so the wrapper root carries none.
func _check_harness_wrapper(report: Report) -> void:
	report.section("harness wrapper")
	var scene: PackedScene = load(POC_SCENE)
	report.check("compositor_poc.tscn loads", scene != null)
	if scene == null:
		return
	var root := scene.instantiate()
	report.check("root is a plain Node3D",
			root is Node3D and root.get_script() == null)

	var screen := root.get_node_or_null("Screen") as MeshInstance3D
	report.check("Screen instance exists", screen != null)
	if screen != null:
		report.check("Screen carries the controller script",
				screen.get_script() != null
						and screen.get_script().resource_path == POC_SCRIPT)
		report.near("Screen y", screen.transform.origin.y, HARNESS_ORIGIN.y)
		report.near("Screen z", screen.transform.origin.z, HARNESS_ORIGIN.z)
	root.free()


## Reads root.tscn's serialized state rather than instantiating it. Starting the
## launcher here would bring up the XR rig and the window manager, which this
## suite has no business doing and cannot do headlessly.
func _check_launcher_integration(report: Report) -> void:
	report.section("root scene integration")
	var scene: PackedScene = load(ROOT_SCENE)
	report.check("root.tscn loads", scene != null)
	if scene == null:
		return

	var state := scene.get_state()
	var index := -1
	for i in state.get_node_count():
		if str(state.get_node_path(i)).trim_prefix("./") == LAUNCHER_NODE_PATH:
			index = i
	report.check("CompositorScreen is a child of WindowManager", index != -1,
			"no node at %s" % LAUNCHER_NODE_PATH)
	if index == -1:
		return

	# get_node_type() is empty for an instanced node; the PackedScene it points
	# at is what identifies it.
	var instance := state.get_node_instance(index)
	report.check("it instances a scene", instance != null)
	report.check("it instances compositor_screen.tscn",
			instance != null and instance.resource_path == SCREEN_SCENE,
			"" if instance == null else instance.resource_path)

	var placed := Vector3.ZERO
	for p in state.get_node_property_count(index):
		if state.get_node_property_name(index, p) == "transform":
			placed = (state.get_node_property_value(index, p) as Transform3D).origin
	report.near("placed x", placed.x, LAUNCHER_ORIGIN.x)
	report.near("placed y", placed.y, LAUNCHER_ORIGIN.y)
	report.near("placed z", placed.z, LAUNCHER_ORIGIN.z)


func _check_descriptor(report: Report) -> void:
	report.section("extension descriptor")
	var config := ConfigFile.new()
	report.check("descriptor parses", config.load(DESCRIPTOR) == OK)
	report.check("entry symbol is set",
			config.get_value("configuration", "entry_symbol", "")
					== "wayland_compositor_init")
	report.check("compatibility_minimum is 4.5",
			str(config.get_value("configuration", "compatibility_minimum", "")) == "4.5")
	# arm64 only, debug and release. Advertising a target nothing builds would
	# be a lie the loader reports as a missing file.
	var libs := config.get_section_keys("libraries")
	report.check("declares linux.debug.arm64", libs.has("linux.debug.arm64"))
	report.check("declares linux.release.arm64", libs.has("linux.release.arm64"))
	report.check("declares nothing else", libs.size() == 2,
			", ".join(libs))
