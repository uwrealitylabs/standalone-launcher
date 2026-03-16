class_name SWindowHeader extends Control

@onready var close_button = $HBoxContainer/CloseButton

signal close_pressed()

# Signals to tell the parent SWindow what the user's hand is doing
signal drag_started(at: Vector3)
signal drag_moved(to: Vector3)
signal drag_ended()

var _last_pointer_pos := Vector3.ZERO

func _ready() -> void:
	close_button.pressed.connect(func(): close_pressed.emit())

func on_pointer_event(event: XRToolsPointerEvent) -> void:
	match event.event_type:
		XRToolsPointerEvent.Type.PRESSED:
			_last_pointer_pos = event.position
			drag_started.emit(event.position)
		XRToolsPointerEvent.Type.MOVED:
			_last_pointer_pos = event.position
			drag_moved.emit(event.position)
		XRToolsPointerEvent.Type.RELEASED:
			drag_ended.emit()
