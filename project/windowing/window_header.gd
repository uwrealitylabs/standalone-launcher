class_name SWindowHeader extends Control

@onready var close_button = $HBoxContainer/CloseButton

signal close_pressed()

func _ready() -> void:
	close_button.pressed.connect(func(): close_pressed.emit())
