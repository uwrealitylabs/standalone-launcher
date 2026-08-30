extends SceneTree

## Verifies the geometry contract stored in window.tscn.
##
## Instantiates the scene without adding it to a tree, so _ready never runs and
## every value checked comes straight off the scene file rather than from
## whatever SWindow would have computed.
##
## Run with:
##   godot --headless --xr-mode off --path . \
##       --script res://tests/window_scene_check.gd
##
## --xr-mode off is required: without it a modal OpenXR alert hangs the run.
##
## The "Viewport Texture must be set to use it" errors are expected with no
## display server, not failures.

const Report := preload("res://tests/support/report.gd")
const Fixtures := preload("res://tests/support/window_fixtures.gd")

const WINDOW_SCENE := "res://project/windowing/window.tscn"

# The sizes window.tscn is authored at. SWindow reads the content size off the
# scene at _ready rather than carrying its own, so this is the only place the
# authored value can be checked; HEADER_HEIGHT is asserted against the constant
# below rather than trusted.
const HEADER_HEIGHT := 0.08
const CONTENT_SIZE := Vector2(1.5, 0.75)

# Must match the throttle_fps window.tscn authors on both surfaces.
const THROTTLE_FPS := 60.0

var _report := Report.new()


func _initialize() -> void:
	var packed: PackedScene = load(WINDOW_SCENE)
	if not packed:
		printerr("could not load ", WINDOW_SCENE)
		quit(1)
		return

	var w1: Node3D = packed.instantiate()
	var w2: Node3D = packed.instantiate()

	_check_constants_agree()
	_check_resources_unshared(w1, w2)
	_check_header_geometry(w1)
	_check_content_geometry(w1)
	_check_redraw_cadence(w1)
	_check_seam(w1)

	w1.free()
	w2.free()

	_report.finish(self)


## The header height this suite measures against must be the one SWindow lays
## the window out with.
func _check_constants_agree() -> void:
	_report.section("constants")
	_report.near("HEADER_HEIGHT tracks SWindow.HEADER_HEIGHT",
			HEADER_HEIGHT, SWindow.HEADER_HEIGHT)
	_report.check("the authored content size is within the resize clamps",
			CONTENT_SIZE.clamp(SWindow.MIN_CONTENT_SIZE,
					SWindow.MAX_CONTENT_SIZE).is_equal_approx(CONTENT_SIZE),
			str(CONTENT_SIZE))


## Header and content must own separate mesh/shape resources, and each window
## instance must own its own copies (resource_local_to_scene), so that resizing
## one surface or one window cannot alter another.
func _check_resources_unshared(w1: Node3D, w2: Node3D) -> void:
	_report.section("unshared resources")
	_report.check("header mesh is not the content mesh",
			not _same(Fixtures.mesh(w1, "Header"), Fixtures.mesh(w1, "Content")))
	_report.check("header shape is not the content shape",
			not _same(Fixtures.shape(w1, "Header"), Fixtures.shape(w1, "Content")))
	_report.check("window instances do not share a header mesh",
			not _same(Fixtures.mesh(w1, "Header"), Fixtures.mesh(w2, "Header")))
	_report.check("window instances do not share a content mesh",
			not _same(Fixtures.mesh(w1, "Content"), Fixtures.mesh(w2, "Content")))
	_report.check("window instances do not share a header shape",
			not _same(Fixtures.shape(w1, "Header"), Fixtures.shape(w2, "Header")))
	_report.check("window instances do not share a content shape",
			not _same(Fixtures.shape(w1, "Content"), Fixtures.shape(w2, "Content")))


## Both surfaces must redraw on the cadence window.tscn authors for them.
##
## Read back off the scene, so re-parenting a surface onto one that carries a
## cadence of its own is caught here.
func _check_redraw_cadence(w: Node3D) -> void:
	_report.section("redraw cadence")
	for part in ["Header", "Content"]:
		var surface: Node3D = w.get_node(part)
		_report.check("%s redraws on a throttle" % part.to_lower(),
				surface.update_mode == XRToolsViewport2DIn3D.UpdateMode.UPDATE_THROTTLED,
				str(surface.update_mode))
		_report.near("%s throttle_fps" % part.to_lower(), surface.throttle_fps, THROTTLE_FPS)


## Header mesh, collider, and both screen_size translators must agree, and the
## header must be unscaled so its screen_size is its true world size.
func _check_header_geometry(w: Node3D) -> void:
	_report.section("header geometry")
	var expected := Vector2(CONTENT_SIZE.x, HEADER_HEIGHT)
	var header: Node3D = w.get_node("Header")
	_report.check("header node is unscaled",
			header.transform.basis.get_scale().is_equal_approx(Vector3.ONE),
			str(header.transform.basis.get_scale()))
	_report.check("header mesh size == %s" % expected,
			Fixtures.mesh(w, "Header").size.is_equal_approx(expected),
			str(Fixtures.mesh(w, "Header").size))
	_report.check("header shape size == %s x 0.02" % expected,
			Fixtures.shape(w, "Header").size.is_equal_approx(
					Vector3(expected.x, expected.y, SWindow.SCREEN_DEPTH)),
			str(Fixtures.shape(w, "Header").size))
	_report.check("header screen_size == %s" % expected,
			header.screen_size.is_equal_approx(expected), str(header.screen_size))
	_report.check("header body screen_size == %s" % expected,
			Fixtures.body(w, "Header").screen_size.is_equal_approx(expected),
			str(Fixtures.body(w, "Header").screen_size))


## Content mesh, collider, and screen_size translator must agree.
func _check_content_geometry(w: Node3D) -> void:
	_report.section("content geometry")
	var content: Node3D = w.get_node("Content")
	_report.check("content node is unscaled",
			content.transform.basis.get_scale().is_equal_approx(Vector3.ONE),
			str(content.transform.basis.get_scale()))
	_report.check("content mesh size == %s" % CONTENT_SIZE,
			Fixtures.mesh(w, "Content").size.is_equal_approx(CONTENT_SIZE),
			str(Fixtures.mesh(w, "Content").size))
	_report.check("content shape size == %s x 0.02" % CONTENT_SIZE,
			Fixtures.shape(w, "Content").size.is_equal_approx(
					Vector3(CONTENT_SIZE.x, CONTENT_SIZE.y, SWindow.SCREEN_DEPTH)),
			str(Fixtures.shape(w, "Content").size))
	_report.check("content screen_size == %s" % CONTENT_SIZE,
			content.screen_size.is_equal_approx(CONTENT_SIZE),
			str(content.screen_size))


## The header must sit directly on top of the content with no gap or overlap.
func _check_seam(w: Node3D) -> void:
	_report.section("header/content seam")
	var header: Node3D = w.get_node("Header")
	var header_bottom: float = header.position.y - Fixtures.mesh(w, "Header").size.y / 2.0
	var content_top: float = w.get_node("Content").position.y \
			+ Fixtures.mesh(w, "Content").size.y / 2.0
	_report.near("header bottom meets content top", header_bottom, content_top)


func _same(a: Resource, b: Resource) -> bool:
	return a != null and b != null and a.get_instance_id() == b.get_instance_id()
