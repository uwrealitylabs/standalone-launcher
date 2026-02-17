extends Node3D
# Window creator and manager system
# Instantiates new window using window.tscn template and stores it in an array

var window_scene: PackedScene = preload("res://windowing/window.tscn")
var windows_list: Array[Node3D] = []


func create_window(position: Vector3 = Vector3.ZERO) -> Node3D:
	var win = window_scene.instantiate()
	win.position = position
	add_child(win)
	windows_list.append(win)
	return win


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	# Create test windows, delete in future
	var win1 = create_window(Vector3(-1.2, 0.5, 0))
	var rect1 = ColorRect.new()
	rect1.color = Color.SKY_BLUE
	rect1.set_anchors_preset(Control.PRESET_FULL_RECT)
	win1.get_node("SubViewport").add_child(rect1)
	
	var win2 = create_window(Vector3(1.2, 0.5, 0))
	var rect2 = ColorRect.new()
	rect2.color = Color.PALE_VIOLET_RED
	rect2.set_anchors_preset(Control.PRESET_FULL_RECT)
	win2.get_node("SubViewport").add_child(rect2)
