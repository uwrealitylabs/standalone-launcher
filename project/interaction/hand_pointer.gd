extends Node3D
class_name HandPointer

## Emitted when the user pinches while pointing at a target
signal pointer_activated(target: Node, position: Vector3)
## Emitted when the ray starts hitting a new target
signal pointer_entered(target: Node)
## Emitted when the ray stops hitting a target
signal pointer_exited(target: Node)

## How close thumb and index need to be to count as a tap
@export_range(0.0, 1.0) var pinch_threshold: float = 0.8
## Cooldown between activations to prevent double-taps
@export var debounce_time: float = 0.15

var _current_target: Node = null
# Target grabbed at pinch start; all gesture events go here until release.
# Gesture positions are ray intersections with the target's LIVE facing
# plane (see _locked_plane_hit) — never collider surface points — so
# tracking continues off-collider and follows z-order changes mid-gesture.
var _locked_target: Node = null
var _was_pinching: bool = false
var _debounce_timer: float = 0.0
var _raycast: RayCast3D = null

# visual elements
var _ray_mesh: MeshInstance3D = null
var _cursor_dot: MeshInstance3D = null


func _ready():
	_raycast = get_parent().get_node_or_null("RayCast3D")
	if not _raycast:
		push_warning("HandPointer: No RayCast3D sibling found")
		return

	# create the visual ray line
	_ray_mesh = MeshInstance3D.new()
	var cylinder = CylinderMesh.new()
	cylinder.top_radius = 0.001
	cylinder.bottom_radius = 0.001
	cylinder.height = 1.0
	_ray_mesh.mesh = cylinder
	_ray_mesh.rotation_degrees.x = 90
	_ray_mesh.visible = false

	var ray_mat = StandardMaterial3D.new()
	ray_mat.albedo_color = Color(0.4, 0.8, 1.0, 0.6)
	ray_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ray_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ray_mesh.material_override = ray_mat
	# The beam lives on the index-fingertip bone (its historical frame): it
	# hangs off the finger along the bone's -Z, tilting with the hand, while
	# the functional ray stays controller-mounted
	var beam_anchor := get_parent().find_child("BoneAttachment3D", true, false)
	if beam_anchor:
		beam_anchor.add_child(_ray_mesh)
	else:
		push_warning("HandPointer: no BoneAttachment3D found; beam stays on pointer")
		add_child(_ray_mesh)

	# create the cursor dot at the hit point
	_cursor_dot = MeshInstance3D.new()
	var sphere = SphereMesh.new()
	sphere.radius = 0.004
	sphere.height = 0.008
	_cursor_dot.mesh = sphere
	_cursor_dot.visible = false

	var dot_mat = StandardMaterial3D.new()
	dot_mat.albedo_color = Color(1.0, 1.0, 1.0, 0.9)
	dot_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dot_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_cursor_dot.material_override = dot_mat
	add_child(_cursor_dot)


func _process(delta: float):
	if not _raycast:
		return

	_debounce_timer = max(0.0, _debounce_timer - delta)

	# get pinch/trigger value from the XR controller
	var pinch_value: float = 0.0
	var controller = _get_controller()
	if controller:
		pinch_value = controller.get_float("trigger")

	# process what the ray is hitting
	_process_hit_test()

	# process pinch activation
	_process_tap(pinch_value)

	# update visuals
	_update_visuals()


func _process_hit_test():
	# Don't retarget mid-gesture; hover state stays on the grabbed target
	if is_instance_valid(_locked_target):
		return
	if _raycast.is_colliding():
		var collider = _raycast.get_collider()
		if collider != _current_target:
			if _current_target:
				pointer_exited.emit(_current_target)
			_current_target = collider
			pointer_entered.emit(_current_target)
	else:
		if _current_target:
			pointer_exited.emit(_current_target)
			_current_target = null


func _process_tap(pinch_value: float):
	var is_pinching = pinch_value >= pinch_threshold

	if is_pinching and not _was_pinching:
		# grab whatever the ray is on; gesture positions come from ray/plane
		# intersections, never raw collision points (those sit on the
		# collider surface, off-plane)
		_locked_target = _current_target
		var hit = _locked_plane_hit()
		if hit != null:
			# print("[hand_pointer] PRESSED hit z=%.5f" % hit.z)
			_send_xr_event(XRToolsPointerEvent.Type.PRESSED, _locked_target, hit)
			if _debounce_timer <= 0.0 and _locked_target:
				pointer_activated.emit(_locked_target, hit)
				_debounce_timer = debounce_time

	# gesture continues even if the ray leaves every collider
	elif is_pinching and _was_pinching:
		var hit = _locked_plane_hit()
		if hit != null:
			# print("[hand_pointer] MOVED hit z=%.5f" % hit.z)
			_send_xr_event(XRToolsPointerEvent.Type.MOVED, _locked_target, hit)

	elif not is_pinching and _was_pinching:
		var hit = _locked_plane_hit()
		if hit != null:
			# print("[hand_pointer] RELEASED hit z=%.5f" % hit.z)
			_send_xr_event(XRToolsPointerEvent.Type.RELEASED, _locked_target, hit)
		_locked_target = null

	_was_pinching = is_pinching


## Intersects the pointer ray with the locked target's facing plane. Returns
## null when there is no locked target or the ray misses the plane this frame.
func _locked_plane_hit() -> Variant:
	if not is_instance_valid(_locked_target):
		return null
	if not _locked_target is Node3D:
		return null
	# Derive the plane from the target's LIVE transform every call so a
	# mid-gesture depth change (e.g. focus raising z-order) moves the plane with
	# it instead of leaving events on a stale depth. Feedback-safe: gestures
	# move windows in X/Y only, while the plane depends only on the target's Z
	# (owned by z-order).
	var t: Transform3D = _locked_target.global_transform
	return Plane(t.basis.z, t.origin).intersects_ray(get_ray_origin(), get_ray_direction())


func _send_xr_event(type: int, target: Node, pos: Vector3):
	if not is_instance_valid(target): return

	# find the parents Viewport node of a child node
	var target_node = target
	if not target_node.has_signal("pointer_event"):
		if target_node.get_parent() and target_node.get_parent().has_signal("pointer_event"):
			target_node = target_node.get_parent()

	if target_node.has_signal("pointer_event"):
		var ev = XRToolsPointerEvent.new(type, self, target_node, pos, Vector3.ZERO)
		target_node.emit_signal("pointer_event", ev)


func _update_visuals():
	if _raycast.is_colliding():
		var hit_point = _raycast.get_collision_point()
		var hit_dist = _ray_mesh.get_parent().global_position.distance_to(hit_point)

		# update ray length to stop at hit point
		_ray_mesh.mesh.height = hit_dist
		_ray_mesh.position.z = -hit_dist / 2.0
		_ray_mesh.visible = true

		# position cursor dot at hit point
		_cursor_dot.global_position = hit_point
		_cursor_dot.visible = true
	else:
		_ray_mesh.visible = false
		_cursor_dot.visible = false


## World-space origin of the pointing ray.
func get_ray_origin() -> Vector3:
	return _raycast.global_transform.origin


## World-space direction the pointing ray travels (RayCast3D points along -Z).
func get_ray_direction() -> Vector3:
	return -_raycast.global_transform.basis.z


func _get_controller() -> XRController3D:
	# walk up the tree to find the XRController3D ancestor
	var node = get_parent()
	while node:
		if node is XRController3D:
			return node
		node = node.get_parent()
	return null
