extends RefCounted

## Helpers shared by the windowing suites: driving a gesture without a live
## HandPointer, and reaching the geometry inside a window instance.


## A pointer event of `type` at `world_pos`, aimed at `target`, carrying no
## pointer.
##
## SWindow._resolve_pointer_hit projects a null pointer's position onto the
## frozen gesture plane rather than casting a ray, which is what lets a headless
## test drive start_drag and start_resize with no controller in the scene.
static func event_at(type: int, target: Node3D, world_pos: Vector3) -> XRToolsPointerEvent:
	return XRToolsPointerEvent.new(type, null, target, world_pos, world_pos)


## A PRESSED event at `world_pos`, as [method event_at].
static func press_at(target: Node3D, world_pos: Vector3) -> XRToolsPointerEvent:
	return event_at(XRToolsPointerEvent.Type.PRESSED, target, world_pos)


## The QuadMesh drawn for `part` ("Header" or "Content") of `win`.
static func mesh(win: Node3D, part: String) -> QuadMesh:
	return (win.get_node(part + "/Screen") as MeshInstance3D).mesh as QuadMesh


## The BoxShape3D collider behind `part` ("Header" or "Content") of `win`.
static func shape(win: Node3D, part: String) -> BoxShape3D:
	return (win.get_node(part + "/StaticBody3D/CollisionShape3D") as CollisionShape3D).shape \
			as BoxShape3D


## The StaticBody3D that translates world hits on `part` into viewport
## coordinates.
static func body(win: Node3D, part: String) -> StaticBody3D:
	return win.get_node(part + "/StaticBody3D") as StaticBody3D


## The SubViewport `part` renders into.
static func viewport(win: Node3D, part: String) -> SubViewport:
	return win.get_node(part + "/Viewport") as SubViewport


## The resize handle body `win` tagged with `handle_id` ("L", "R", "B", "BL" or
## "BR"), or null when the window has no such handle.
static func handle(win: Node3D, handle_id: String) -> StaticBody3D:
	var handles := win.get_node_or_null("ResizeHandles")
	if handles == null:
		return null
	for child in handles.get_children():
		if child.get_meta("handle_id", "") == handle_id:
			return child as StaticBody3D
	return null
