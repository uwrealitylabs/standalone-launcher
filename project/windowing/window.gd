class_name StandaloneWindow extends Node3D

@onready var viewport: SubViewport = $SubViewport
@onready var mesh: MeshInstance3D = $MeshInstance3D

#Placeholder for the world bounds -> not sure where window boundaries are yet
var world_bounds := AABB(Vector3(-10, 0.2, -10), Vector3(16, 6, 0))

#Variables to track window dragging
var window_size := Vector2(2.0, 1.5)
var _dragging   := false
var _drag_offset := Vector3.ZERO
@onready var content_container: Control = $SubViewport/VBoxContainer/ContentContainer
@onready var close_button: Button = $SubViewport/VBoxContainer/HBoxContainer/CloseButton
@export var follow_speed: float = 15.0 #can change speed depending on what we want

signal on_closed()

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	# Create a material that will display SubViewport content
	var mat :=  StandardMaterial3D.new()
	mat.albedo_texture = viewport.get_texture()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh.material_override = mat
	close_button.text = "x"
	close_button.pressed.connect(close)

func set_content(content: Control) -> void:
	_clear_content()
	content_container.add_child(content)
	
func start_drag(hit_world: Vector3) -> void:
	_dragging = true
	_drag_offset = global_position - hit_world

func update_drag(hit_world: Vector3, delta: float) -> void:
    if not _dragging:
        return
    var target_pos = _clamp_to_bounds(hit_world + _drag_offset)
    global_position = global_position.lerp(target_pos, 1.0 - exp(-follow_speed * delta))
    _face_user()

# This isn't really used right now, but in the future when we need to display more complex
# applications on the window, it will prolly be a PackedScene
func set_content_scene(content_scene: PackedScene) -> void:
	_clear_content()
	var content = content_scene.instantiate()
	content_container.add_child(content)

func _clear_content() -> void:
	for child in content_container.get_children():
		child.queue_free()
	
#Helper function to keep window within world boundaries
func _clamp_to_bounds(pos: Vector3) -> Vector3:
	pos.x = clamp(pos.x, world_bounds.position.x, world_bounds.end.x)
	pos.y = clamp(pos.y, world_bounds.position.y, world_bounds.end.y)
	pos.z = clamp(pos.z, world_bounds.position.z, world_bounds.end.z)
	return pos

#Helper function so that the window always faces the user and doesn't tilt around
func _face_user() -> void:
    var camera = get_viewport().get_camera_3d()
    if not camera:
        return
    var target_pos = camera.global_position
    target_pos.y = global_position.y 
    
    look_at(target_pos, Vector3.UP)
 
    rotate_object_local(Vector3.UP, PI) #TODO may need to flip around to face -Z

# The window's self-cleaning function that destroys window content
func close() -> void:
	_clear_content()
	on_closed.emit()
	queue_free()
