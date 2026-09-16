extends SceneTree

## Verifies the host-independent half of compositor_poc.gd's shutdown state
## machine -- the paths that run with no GDExtension, which are exactly the ones
## root.gd relies on to quit cleanly on every dev machine.
##
## On a host where WaylandCompositor is registered (the arm64 VM, the board),
## request_shutdown would signal a real client, so this suite skips there and
## defers to tests/linux/poc_shutdown.gd, which owns the live-client paths.
##
## The invariants, all on a dormant node (extension absent, no client spawned):
##   - request_shutdown emits shutdown_finished even with nothing to stop, so a
##     caller's `await shutdown_finished` cannot hang
##   - that emit is deferred, not synchronous, so a caller awaiting right after
##     the request never misses it
##   - it fires exactly once no matter how many times shutdown is requested
##   - a request after completion does not emit again
##   - the node stops processing and frees cleanly afterwards
##
## Run with:
##   godot --headless --xr-mode off --path . \
##       --script res://tests/compositor_shutdown_check.gd

const Report := preload("res://tests/support/report.gd")

const SCREEN_SCENE := "res://project/compositor/compositor_screen.tscn"


func _initialize() -> void:
	var report := Report.new()

	var scene: PackedScene = load(SCREEN_SCENE)
	report.check("compositor_screen.tscn loads", scene != null)
	if scene == null:
		report.finish(self)
		return

	if ClassDB.class_exists("WaylandCompositor"):
		print("")
		print("  -- skipped: WaylandCompositor is registered on this host, so")
		print("     request_shutdown would drive a real client. The live-client")
		print("     paths live in tests/linux/poc_shutdown.gd.")
		report.finish(self)
		return

	var screen := scene.instantiate() as MeshInstance3D
	report.check("instantiates as a MeshInstance3D", screen != null)
	if screen == null:
		report.finish(self)
		return
	get_root().add_child(screen)
	# The tree's own root is not inside the tree during _initialize, so this
	# frame is what actually runs the node's _ready.
	await process_frame

	report.section("dormant node, no extension")
	report.check("entered the tree", screen.is_inside_tree())
	report.check("not processing after a dormant _ready", not screen.is_processing())

	# Count every emission for the life of the node: the contract is exactly one.
	# An Array holds the count so the lambda mutates a shared reference.
	var emitted := [0]
	screen.shutdown_finished.connect(func() -> void: emitted[0] += 1)

	screen.request_shutdown()
	# Deferred by design: had it fired synchronously here, a caller doing
	# `request_shutdown(); await shutdown_finished` would miss it and stall.
	report.check("emit is deferred, not synchronous", emitted[0] == 0,
			"%d emissions" % emitted[0])
	# A second request before the first completes must not queue a second emit.
	screen.request_shutdown()

	# Let the deferred completion run; a second frame would surface a stray emit.
	await process_frame
	await process_frame

	report.section("after shutdown")
	report.check("shutdown_finished fired", emitted[0] >= 1)
	report.check("fired exactly once", emitted[0] == 1, "%d emissions" % emitted[0])
	report.check("still not processing", not screen.is_processing())

	# A request after completion is a no-op: no second teardown, no second emit.
	screen.request_shutdown()
	await process_frame
	report.check("no re-emit after completion", emitted[0] == 1,
			"%d emissions" % emitted[0])

	# Freeing runs _exit_tree with nothing left to stop; it must neither fault on
	# the null references nor emit again.
	screen.free()
	report.check("frees cleanly after shutdown", true)
	report.check("no emit on free", emitted[0] == 1, "%d emissions" % emitted[0])

	report.finish(self)
