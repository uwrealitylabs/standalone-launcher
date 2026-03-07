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
var _was_pinching: bool = false
var _debounce_timer: float = 0.0
var _raycast: RayCast3D = null

# visual elements
var _ray_mesh: MeshInstance3D = null
var _cursor_dot: MeshInstance3D = null


func _ready():
	# find the RayCast3D sibling (the one you added in step 1)
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

	# detect rising edge: pinch just started this frame
	if is_pinching and not _was_pinching:
		if _current_target and _debounce_timer <= 0.0:
			var hit_pos = _raycast.get_collision_point()
			pointer_activated.emit(_current_target, hit_pos)
			_debounce_timer = debounce_time

	_was_pinching = is_pinching


func _update_visuals():
	if _raycast.is_colliding():
		var hit_point = _raycast.get_collision_point()
		var hit_dist = global_position.distance_to(hit_point)

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


func _get_controller() -> XRController3D:
	# walk up the tree to find the XRController3D ancestor
	var node = get_parent()
	while node:
		if node is XRController3D:
			return node
		node = node.get_parent()
	return null
