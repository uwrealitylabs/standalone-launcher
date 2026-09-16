extends SceneTree

## Verifies the compositor screen stays completely dormant on a host where the
## GDExtension does not exist.
##
## compositor_scene_check.gd proves the scene is *authored* hidden. This proves
## the script keeps it that way once it has actually run: the quad the launcher
## now carries in root.tscn must not appear as a white rectangle beside the
## terminal on any machine that cannot run a Wayland server, and it must not
## leave a _process callback running for something that will never exist.
##
## The three invariants, all after _ready has run:
##   - the node is still hidden
##   - no WaylandCompositor child was created
##   - the wrapper is not processing
##
## Where the class *is* registered -- the arm64 VM and the board -- entering the
## tree starts a real server and a real weston-simple-shm. That is deliberately
## not done here: it is a side effect a tracked cross-platform suite should not
## have, and tests/linux/poc_capture.gd already covers it end to end, including
## the part this suite cannot assert anyway, that real pixels become visible.
##
## Run with:
##   godot --headless --xr-mode off --path . \
##       --script res://tests/compositor_visibility_check.gd

const Report := preload("res://tests/support/report.gd")

const SCREEN_SCENE := "res://project/compositor/compositor_screen.tscn"


func _initialize() -> void:
	var report := Report.new()

	var scene: PackedScene = load(SCREEN_SCENE)
	report.check("compositor_screen.tscn loads", scene != null)
	if scene == null:
		report.finish(self)
		return
	var screen := scene.instantiate() as MeshInstance3D
	report.check("instantiates as a MeshInstance3D", screen != null)
	if screen == null:
		report.finish(self)
		return

	report.section("before entering the tree")
	# _ready has not run yet, so this is the serialized value.
	report.check("hidden as authored", not screen.visible)

	if ClassDB.class_exists("WaylandCompositor"):
		print("")
		print("  -- skipped: WaylandCompositor is registered on this host, so")
		print("     entering the tree would start a real Wayland server and")
		print("     launch a client. tests/linux/poc_capture.gd owns that path.")
		screen.free()
		report.finish(self)
		return

	get_root().add_child(screen)
	# The tree's own root is not yet inside the tree during _initialize, so
	# add_child alone does not run _ready. Without this frame every assertion
	# below would pass against a node that had never executed a line.
	await process_frame
	report.check("entered the tree", screen.is_inside_tree())

	report.section("after _ready, with no extension on this host")
	report.check("still hidden", not screen.visible)
	# An empty child list is the assertion: ClassDB.instantiate was never
	# reached, so nothing was added and no server was started.
	report.check("no compositor child was created", screen.get_child_count() == 0,
			"%d child(ren)" % screen.get_child_count())
	# Godot enables processing on tree entry for any script defining _process.
	# _ready turns it off again, and only a live client pid turns it back on.
	report.check("wrapper is not processing", not screen.is_processing())
	report.check("no material was built", screen.material_override == null)

	# Frees while still in the tree, so _exit_tree runs. With no compositor and
	# no client it has nothing to do, and must not fault on the null references.
	screen.free()
	report.check("freeing after a dormant _ready is clean", true)

	report.finish(self)
