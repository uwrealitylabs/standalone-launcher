extends Control

@onready var input_line: LineEdit = $VBoxContainer/InputLine
@onready var output_display: RichTextLabel = $VBoxContainer/OutputDisplay

func _ready():
	add_to_group("terminal_group")
	input_line.grab_focus.call_deferred()
	display_text("[color=yellow]SYSTEM READY[/color]")

func _process(_delta):
	if output_display.size.y < 10:
		output_display.custom_minimum_size.y = 200

func vr_type(text: String):
	input_line.insert_text_at_caret(text)

func vr_backspace():
	input_line.delete_char_at_caret()

func vr_enter() -> String:
	var cmd = input_line.text
	input_line.clear()
	input_line.grab_focus()
	return cmd

func display_text(text: String):
	output_display.append_text(text + "\n")
	output_display.scroll_to_line(output_display.get_line_count())
