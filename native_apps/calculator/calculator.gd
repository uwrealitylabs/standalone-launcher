extends Node3D
class_name Calculator

@export var button_scene: PackedScene
@export var button_size: float = 0.04
@export var gap: float = 0.012

@onready var display: CalcDisplay = $Display

const LAYOUT := [
	["C", "(", ")", "÷"],
	["7", "8", "9", "×"],
	["4", "5", "6", "-"],
	["1", "2", "3", "+"],
	["0", ".", "←", "="],
]

# show ÷ ×, but feed / * to the math parser
const VALUE_MAP := { "÷": "/", "×": "*" }

func _ready() -> void:
	var pitch := button_size + gap
	var cols := LAYOUT[0].size()
	var rows := LAYOUT.size()
	for r in rows:
		for c in LAYOUT[r].size():
			var label: String = LAYOUT[r][c]
			var b: XRButton = button_scene.instantiate()
			$Buttons.add_child(b)
			b.custom_label = label
			b.value = VALUE_MAP.get(label, label)
			b.position = Vector3(
				(c - (cols - 1) * 0.5) * pitch,
				0,
				(r - (rows - 1) * 0.5) * pitch
			)
			b.pressed.connect(_on_button_pressed.bind(b))

func _on_button_pressed(_key, b: XRButton) -> void:
	display.input_token(b.get_token())
