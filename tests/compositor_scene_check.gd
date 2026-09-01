extends SceneTree

## Verifies compositor_poc.tscn loads and is authored correctly on every host,
## including hosts with no GDExtension built.
##
## That last part is the point. The Wayland extension is Linux-arm64 only, so on
## macOS and on x86_64 CI `WaylandCompositor` does not exist; the scene must
## still load and the script must still parse, or the whole project stops
## opening in the editor for everyone who is not on the target.
##
## Instantiates without adding to a tree, so _ready never runs and the values
## checked come from the scene file rather than from runtime.
##
## Run with:
##   godot --headless --xr-mode off --path . \
##       --script res://tests/compositor_scene_check.gd

const Report := preload("res://tests/support/report.gd")

const POC_SCENE := "res://project/compositor/compositor_poc.tscn"
const POC_SCRIPT := "res://project/compositor/compositor_poc.gd"
const DESCRIPTOR := "res://project/compositor/wayland_compositor.gdextension"

# The quad is authored square and re-aspected at runtime from the surface size.
const AUTHORED_QUAD_SIZE := Vector2(0.6, 0.6)


func _init() -> void:
	var report := Report.new()

	report.section("scene loads without the extension")
	var scene: PackedScene = load(POC_SCENE)
	report.check("compositor_poc.tscn loads", scene != null)
	if scene == null:
		report.finish(self)
		return
	var root := scene.instantiate()
	report.check("instantiates", root != null)
	if root == null:
		report.finish(self)
		return

	report.check("root is a Node3D", root is Node3D)
	report.check("script is attached",
			root.get_script() != null and root.get_script().resource_path == POC_SCRIPT)

	report.section("screen quad")
	var screen: MeshInstance3D = root.get_node_or_null("Screen")
	report.check("Screen node exists", screen != null)
	if screen != null:
		var mesh := screen.mesh as QuadMesh
		report.check("Screen uses a QuadMesh", mesh != null)
		if mesh != null:
			report.near("quad width", mesh.size.x, AUTHORED_QUAD_SIZE.x)
			report.near("quad height", mesh.size.y, AUTHORED_QUAD_SIZE.y)
		# In front of the player at roughly eye height, so the proof is visible
		# without moving.
		report.check("quad sits in front of the origin",
				screen.transform.origin.z < 0.0,
				"%.3f" % screen.transform.origin.z)
		report.check("quad sits above the floor",
				screen.transform.origin.y > 0.5,
				"%.3f" % screen.transform.origin.y)

	report.section("no compositor node is authored into the scene")
	# The node is created at runtime only when the class exists. Authoring it
	# into the .tscn would make the scene fail to load wherever the extension
	# is not built, which is everywhere except the board and the VM.
	var authored_compositor := false
	for child in root.get_children():
		if child.get_class() == "WaylandCompositor":
			authored_compositor = true
	report.check("scene has no WaylandCompositor node", not authored_compositor)

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

	root.free()
	report.finish(self)
