class_name StandaloneWindow extends Node3D

@onready var viewport: SubViewport = $SubViewport
@onready var mesh: MeshInstance3D = $MeshInstance3D
@onready var content_container: Control = $SubViewport/VBoxContainer/ContentContainer
@onready var close_button: Button = $SubViewport/VBoxContainer/HBoxContainer/CloseButton

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

# This isn't really used right now, but in the future when we need to display more complex
# applications on the window, it will prolly be a PackedScene
func set_content_scene(content_scene: PackedScene) -> void:
	_clear_content()
	var content = content_scene.instantiate()
	content_container.add_child(content)

func _clear_content() -> void:
	for child in content_container.get_children():
		child.queue_free()

# The window's self-cleaning function that destroys window content
func close() -> void:
	_clear_content()
	on_closed.emit()
	queue_free()
