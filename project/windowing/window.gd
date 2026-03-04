class_name StandaloneWindow extends Node3D

@onready var viewport: SubViewport = $SubViewport
@onready var mesh: MeshInstance3D = $MeshInstance3D

#Placeholder for the world bounds -> not sure where window boundaries are yet
var world_bounds := AABB(Vector3(-10, 0.2, -10), Vector3(16, 6, 0))

#Variables to track window dragging
var window_size := Vector2(2.0, 1.5)
var _dragging   := false
var _drag_offset := Vector3.ZERO

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	# Create a material that will display SubViewport content
	var mat :=  StandardMaterial3D.new()
	mat.albedo_texture = viewport.get_texture()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh.material_override = mat

func set_content(content: Control) -> void:
	_clear_viewport()
	viewport.add_child(content)
	
func start_drag(hit_world: Vector3) -> void:
	_dragging = true
	_drag_offset = global_position - hit_world

# This isn't really used right now, but in the future when we need to display more complex
# applications on the window, it will prolly be a PackedScene
func set_content_scene(content_scene: PackedScene) -> void:
	_clear_viewport()
	var content = content_scene.instantiate()
	viewport.add_child(content)

func _clear_viewport() -> void:
	for child in viewport.get_children():
		child.queue_free()
	
#Helper function to keep window within world boundaries
func _clamp_to_bounds(pos: Vector3) -> Vector3:
	pos.x = clamp(pos.x, world_bounds.position.x, world_bounds.end.x)
	pos.y = clamp(pos.y, world_bounds.position.y, world_bounds.end.y)
	pos.z = clamp(pos.z, world_bounds.position.z, world_bounds.end.z)
	return pos
