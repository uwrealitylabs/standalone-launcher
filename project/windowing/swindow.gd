class_name SWindow extends Node3D

@export_group("Content")
@export var content: PackedScene

@export_group("References")
@export var header_3d: XRToolsViewport2DIn3D
@export var content_3d: XRToolsViewport2DIn3D

signal on_closed()
signal on_focused(win: SWindow)

## This window's depth order (higher = more in front)
var z_order: int = 0

## The depth offset per z-order level (in meters)
const Z_STEP: float = 0.05

## Base position before z-order offset is applied
var base_position: Vector3 = Vector3.ZERO


func _ready() -> void:
	base_position = position

	var window_header: SWindowHeader = header_3d.get_scene_instance()
	window_header.close_pressed.connect(close)
	
	set_content(content)
	set_input_enabled(false)
	
	header_3d.pointer_event.connect(_on_pointer_event)
	content_3d.pointer_event.connect(_on_pointer_event)
	
	if not XRUtils.is_openxr_active():
		content_3d.set_process_input(false)
	

## Invoked when a pointer event on the window is detected
func _on_pointer_event(event: XRToolsPointerEvent):
	if event.event_type == XRToolsPointerEvent.Type.PRESSED:  # Focus this window when "pressed"
		focus()


## Send input event to this window
func send_input(event: InputEvent):
	content_3d._input(event)


## Sets the window's content to the given UI scene
func set_content(new_content: PackedScene) -> void:
	content_3d.set_scene(new_content)
	content = new_content


## Call this to tell the window manager to bring this window to front
func focus() -> void:
	on_focused.emit(self)
	
	
## Sets whether input events will be directed to this window
func set_input_enabled(enabled: bool) -> void:
	content_3d.input_keyboard = enabled
	content_3d.input_gamepad = enabled

## Updates the window's position based on its z-order
func apply_z_order() -> void:                                                                                    ##67 :)
	# move the window forward (toward the user) based on z_order
	position = base_position + Vector3(0, 0, z_order * Z_STEP)

## Visual feedback when the current window becomes the focused window
func set_focused_visual(is_focused: bool) -> void:
	var mat: StandardMaterial3D = $Header/Screen.material_override as StandardMaterial3D
	if not mat:
		return
	if is_focused:
		mat.albedo_color = Color(1.0, 1.0, 1.0, 1.0)
	else:
		mat.albedo_color = Color(0.6, 0.6, 0.6, 1.0)

## Self-cleaning function that destroys window content
func close() -> void:
	on_closed.emit()
	queue_free()
