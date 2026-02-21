# InputLine.gd
extends LineEdit

func _ready():
	# Ensure the cursor blinks and the box is active
	focus_mode = Control.FOCUS_ALL 
	grab_focus()

func _gui_input(event):
	if event is InputEventKey:
		# THE SECRET SAUCE:
		# Physical key presses from your laptop have a device ID of 0 or higher.
		# Script-generated events (like the VR Keyboard) often have unique signatures.
		# But the safest way is to check if the event is "echo" or "pressed" 
		# and only accept it if it's NOT coming from the global OS.
		
		# For most VR Simulators, we want to block ALL global OS key events
		# but allow our manual 'insert_text' calls to work.
		accept_event() 

# This function is called ONLY by your VR Bridge script.
# Since it's a direct function call, it bypasses _gui_input entirely!
func vr_type(text_to_add):
	self.insert_text_at_caret(text_to_add)

func vr_backspace():
	self.delete_char_at_caret()
