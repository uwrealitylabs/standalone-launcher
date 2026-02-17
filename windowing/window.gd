extends Node3D

@onready var viewport: SubViewport = $SubViewport
@onready var mesh: MeshInstance3D = $MeshInstance3D

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

# This isn't really used right now, but in the future when we need to display more complex
# applications on the window, it will prolly be a PackedScene
func set_content_scene(content_scene: PackedScene) -> void:
	_clear_viewport()
	var content = content_scene.instantiate()
	viewport.add_child(content)

func _clear_viewport() -> void:
	for child in viewport.get_children():
		child.queue_free()
