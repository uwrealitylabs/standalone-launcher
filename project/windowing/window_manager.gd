extends Node3D
# Window creator and manager system
# Instantiates new window using window.tscn template and stores it in an array

@export var window_scene: PackedScene
var windows_list: Array[Node3D] = []

func create_window(pos: Vector3 = Vector3.ZERO) -> Node3D:
	var win: StandaloneWindow = window_scene.instantiate()
	win.position = pos
	add_child(win)
	windows_list.append(win)
	win.on_closed.connect(func(): _on_window_closed(win))
	return win

func destroy_window(win: Node3D) -> void:
	if win in windows_list:
		win.close()

# Remove window from window manager list
func _on_window_closed(win: Node3D) -> void:
	print("removed from window list")
	windows_list.erase(win)

func _ready() -> void:
	# Create test windows, delete in future
	var win1 = create_window(Vector3(-1.2, 0.5, 0))
	var rect1 = ColorRect.new()
	rect1.color = Color.SKY_BLUE
	rect1.set_anchors_preset(Control.PRESET_FULL_RECT)
	win1.set_content(rect1)
	
	var win2 = create_window(Vector3(1.2, 0.5, 0))
	var rect2 = ColorRect.new()
	rect2.color = Color.PALE_VIOLET_RED
	rect2.set_anchors_preset(Control.PRESET_FULL_RECT)
	win2.set_content(rect2)
	
	# Manually testing the close function
	await get_tree().create_timer(3.0).timeout
	win2.close()
