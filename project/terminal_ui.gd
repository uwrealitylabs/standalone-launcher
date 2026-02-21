extends Control

@onready var input_line: LineEdit = $VBoxContainer/InputLine
@onready var output_display: RichTextLabel = $VBoxContainer/OutputDisplay

func _ready():
	add_to_group("terminal_group")
	input_line.grab_focus.call_deferred()
	input_line.caret_blink = true

# This handles the VR Keyboard pokes
func vr_type(text: String):
	input_line.insert_text_at_caret(text)

func vr_backspace():
	input_line.delete_char_at_caret()

func vr_enter():
	var cmd = input_line.text
	input_line.clear()
	return cmd

func display_text(text: String):
	output_display.append_text(text + "\n")
	output_display.scroll_to_line(output_display.get_line_count())
