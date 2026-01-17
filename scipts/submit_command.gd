extends Button


func _on_pressed() -> void:
	var output: Array[String] = []
	var input: String = $"../TextEdit".text
	print("Executing command V2 '%s'" % input)
	match OS.get_name():
		"Windows":
			OS.execute("CMD.exe", ["/C", input], output, true)
		"Linux", "X11":
			var split_input: PackedStringArray = input.split(" ") 
			var path: String = split_input[0]
			var args: PackedStringArray = PackedStringArray(Array(split_input).slice(1))
			OS.execute(path, args, output, true)
		_:
			print("Unknown OS!")
	print(output)
	var output_text = ""
	for line in output:
		output_text += line + "\n"
	$"../ScrollContainer/Label".text = output_text
