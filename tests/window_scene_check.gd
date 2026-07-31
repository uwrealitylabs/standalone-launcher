extends SceneTree

## Verifies the geometry contract stored in window.tscn.
##
## Instantiates the scene without adding it to a tree, so _ready never runs and
## every value checked comes straight off the scene file. Run with:
##   godot --headless --path . --script res://tests/window_scene_check.gd

const WINDOW_SCENE := "res://project/windowing/window.tscn"

# Must match SWindow.HEADER_HEIGHT and the QuadMesh default in window.tscn.
const HEADER_HEIGHT := 0.08
const CONTENT_SIZE := Vector2(1.5, 0.75)

var _failures := 0


func _initialize() -> void:
	var packed: PackedScene = load(WINDOW_SCENE)
	if not packed:
		printerr("could not load ", WINDOW_SCENE)
		quit(1)
		return

	var w1: Node3D = packed.instantiate()
	var w2: Node3D = packed.instantiate()

	_check_resources_unshared(w1, w2)
	_check_header_geometry(w1)
	_check_content_geometry(w1)
	_check_seam(w1)
	_check_content_resize_leaves_header_alone(w1)

	w1.free()
	w2.free()

	print("")
	if _failures == 0:
		print("PASS - all checks passed")
		quit(0)
	else:
		print("FAIL - %d check(s) failed" % _failures)
		quit(1)


## Header and content must own separate mesh/shape resources, and each window
## instance must own its own copies (resource_local_to_scene).
func _check_resources_unshared(w1: Node3D, w2: Node3D) -> void:
	print("[unshared resources]")
	_check("header mesh is not the content mesh",
			not _same(_mesh(w1, "Header"), _mesh(w1, "Content")))
	_check("header shape is not the content shape",
			not _same(_shape(w1, "Header"), _shape(w1, "Content")))
	_check("window instances do not share a header mesh",
			not _same(_mesh(w1, "Header"), _mesh(w2, "Header")))
	_check("window instances do not share a content mesh",
			not _same(_mesh(w1, "Content"), _mesh(w2, "Content")))
	_check("window instances do not share a header shape",
			not _same(_shape(w1, "Header"), _shape(w2, "Header")))
	_check("window instances do not share a content shape",
			not _same(_shape(w1, "Content"), _shape(w2, "Content")))


## Header mesh, collider, and both screen_size translators must agree, and the
## header must be unscaled so its screen_size is its true world size.
func _check_header_geometry(w: Node3D) -> void:
	print("[header geometry]")
	var expected := Vector2(CONTENT_SIZE.x, HEADER_HEIGHT)
	var header: Node3D = w.get_node("Header")
	_check("header node is unscaled", header.transform.basis.get_scale().is_equal_approx(Vector3.ONE),
			str(header.transform.basis.get_scale()))
	_check("header mesh size == %s" % expected, _mesh(w, "Header").size.is_equal_approx(expected),
			str(_mesh(w, "Header").size))
	_check("header shape size == %s x 0.02" % expected,
			_shape(w, "Header").size.is_equal_approx(Vector3(expected.x, expected.y, 0.02)),
			str(_shape(w, "Header").size))
	_check("header screen_size == %s" % expected, header.screen_size.is_equal_approx(expected),
			str(header.screen_size))
	_check("header body screen_size == %s" % expected,
			w.get_node("Header/StaticBody3D").screen_size.is_equal_approx(expected),
			str(w.get_node("Header/StaticBody3D").screen_size))


## Content mesh, collider, and screen_size translator must agree.
func _check_content_geometry(w: Node3D) -> void:
	print("[content geometry]")
	var content: Node3D = w.get_node("Content")
	_check("content node is unscaled",
			content.transform.basis.get_scale().is_equal_approx(Vector3.ONE),
			str(content.transform.basis.get_scale()))
	_check("content mesh size == %s" % CONTENT_SIZE,
			_mesh(w, "Content").size.is_equal_approx(CONTENT_SIZE), str(_mesh(w, "Content").size))
	_check("content shape size == %s x 0.02" % CONTENT_SIZE,
			_shape(w, "Content").size.is_equal_approx(Vector3(CONTENT_SIZE.x, CONTENT_SIZE.y, 0.02)),
			str(_shape(w, "Content").size))
	_check("content screen_size == %s" % CONTENT_SIZE,
			content.screen_size.is_equal_approx(CONTENT_SIZE), str(content.screen_size))


## The header must sit directly on top of the content with no gap or overlap.
func _check_seam(w: Node3D) -> void:
	print("[header/content seam]")
	var header: Node3D = w.get_node("Header")
	var header_bottom: float = header.position.y - _mesh(w, "Header").size.y / 2.0
	var content_top: float = w.get_node("Content").position.y + _mesh(w, "Content").size.y / 2.0
	_check("header bottom meets content top", is_equal_approx(header_bottom, content_top),
			"header_bottom=%.5f content_top=%.5f" % [header_bottom, content_top])


## Asserts that resizing the content leaves the header's geometry untouched.
func _check_content_resize_leaves_header_alone(w: Node3D) -> void:
	print("[content resize isolation]")
	var header_mesh_before: Vector2 = _mesh(w, "Header").size
	var header_shape_before: Vector3 = _shape(w, "Header").size

	var grown := Vector2(2.4, 1.8)
	_mesh(w, "Content").size = grown
	_shape(w, "Content").size = Vector3(grown.x, grown.y, 0.02)

	_check("header mesh unchanged after content grows",
			_mesh(w, "Header").size.is_equal_approx(header_mesh_before),
			str(_mesh(w, "Header").size))
	_check("header shape unchanged after content grows",
			_shape(w, "Header").size.is_equal_approx(header_shape_before),
			str(_shape(w, "Header").size))
	_check("content mesh actually grew", _mesh(w, "Content").size.is_equal_approx(grown))


func _mesh(w: Node3D, part: String) -> QuadMesh:
	return (w.get_node(part + "/Screen") as MeshInstance3D).mesh as QuadMesh


func _shape(w: Node3D, part: String) -> BoxShape3D:
	return (w.get_node(part + "/StaticBody3D/CollisionShape3D") as CollisionShape3D).shape \
			as BoxShape3D


func _same(a: Resource, b: Resource) -> bool:
	return a != null and b != null and a.get_instance_id() == b.get_instance_id()


func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		print("  ok   ", label)
	else:
		_failures += 1
		print("  FAIL ", label, "" if detail.is_empty() else "  (got %s)" % detail)
