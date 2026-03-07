class_name StandaloneWindow extends Node3D

@onready var viewport: SubViewport = $SubViewport
@onready var mesh: MeshInstance3D = $MeshInstance3D
@onready var content_container: Control = $SubViewport/VBoxContainer/ContentContainer
@onready var close_button: Button = $SubViewport/VBoxContainer/HBoxContainer/CloseButton
@onready var static_body: StaticBody3D = $StaticBody3D

signal on_closed()
signal on_focused(win: StandaloneWindow)

## This window's depth order (higher = more in front)
var z_order: int = 0

## The depth offset per z-order level (in meters)
const Z_STEP: float = 0.05

## Base position before z-order offset is applied
var base_position: Vector3 = Vector3.ZERO


func _ready() -> void:
	# This stores original position
	base_position = position

	# create a material that will display SubViewport content
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = viewport.get_texture()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh.material_override = mat

	close_button.text = "x"
	close_button.pressed.connect(close)


func set_content(content: Control) -> void:
	_clear_content()
	content_container.add_child(content)


func set_content_scene(content_scene: PackedScene) -> void:
	_clear_content()
	var content = content_scene.instantiate()
	content_container.add_child(content)


func _clear_content() -> void:
	for child in content_container.get_children():
		child.queue_free()


## Call this to tell the window manager to bring this window to front
func focus() -> void:
	on_focused.emit(self)


## Updates the window's position based on its z-order
func apply_z_order() -> void:
	# move the window forward (toward the user) based on z_order
	position = base_position + Vector3(0, 0, z_order * Z_STEP)

## Visual feedback when the current window becomes the focused window
func set_focused_visual(is_focused: bool) -> void:
	var mat = mesh.material_override as StandardMaterial3D
	if not mat:
		return
##67 :)
	if is_focused:
		mat.albedo_color = Color(1.0, 1.0, 1.0, 1.0)
	else:
		mat.albedo_color = Color(0.6, 0.6, 0.6, 1.0)

## Self-cleaning function that destroys window content
func close() -> void:
	_clear_content()
	on_closed.emit()
	queue_free()
