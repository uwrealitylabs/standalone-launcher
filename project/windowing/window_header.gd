class_name SWindowHeader extends Control

@onready var solo_button: Button = $HBoxContainer/SoloButton
@onready var close_button: Button = $HBoxContainer/CloseButton

signal solo_pressed()
signal close_pressed()

func _ready() -> void:
	solo_button.pressed.connect(func(): solo_pressed.emit())
	close_button.pressed.connect(func(): close_pressed.emit())
