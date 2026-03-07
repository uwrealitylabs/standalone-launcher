extends XRToolsInteractableBody

## Detects pointer interaction and focuses the parent window

func _ready():
	pointer_event.connect(_on_pointer_event)


func _on_pointer_event(event: XRToolsPointerEvent) -> void:
	# detect a press event (finger tap or trigger click)
	if event.event_type == XRToolsPointerEvent.Type.PRESSED:
		var window = get_parent() as StandaloneWindow
		if window:
			window.focus()
