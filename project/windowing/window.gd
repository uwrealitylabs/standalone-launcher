class_name StandaloneWindow extends Node3D

@export var content: PackedScene

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

	var window_header: SWindowHeader = $Header.get_scene_instance()
	window_header.close_pressed.connect(close)
	
	set_content(content)
	
	# Focus on any pointer event on this window
	$Header.pointer_event.connect(_on_pointer_event)
	$Content.pointer_event.connect(_on_pointer_event)
	

## Invoked when a pointer event on the window is detected
func _on_pointer_event(event: XRToolsPointerEvent):
	if event.event_type == XRToolsPointerEvent.Type.PRESSED:
		focus()


## Sets the window's content to the given UI scene
func set_content(new_content: PackedScene) -> void:
	$Content.set_scene(new_content)
	content = new_content


## Call this to tell the window manager to bring this window to front
func focus() -> void:
	on_focused.emit(self)


## Updates the window's position based on its z-order
func apply_z_order() -> void:
	# move the window forward (toward the user) based on z_order
	position = base_position + Vector3(0, 0, z_order * Z_STEP)

## Visual feedback when the current window becomes the focused window
func set_focused_visual(is_focused: bool) -> void:
	var mat = $Header/Screen.material_override as StandardMaterial3D
	if not mat:
		return
##67 :)
	if is_focused:
		mat.albedo_color = Color(1.0, 1.0, 1.0, 1.0)
	else:
		mat.albedo_color = Color(0.6, 0.6, 0.6, 1.0)

## Self-cleaning function that destroys window content
func close() -> void:
	on_closed.emit()
	queue_free()
