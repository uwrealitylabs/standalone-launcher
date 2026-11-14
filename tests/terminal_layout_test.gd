extends SceneTree

## Verifies that the terminal fits its window's viewport: the input line stays on
## screen and the output fills the height below it.
##
## Run with:
##   godot --headless --xr-mode off --path . \
##       --script res://tests/terminal_layout_test.gd

const Report := preload("res://tests/support/report.gd")

const TERMINAL_SCENE := "res://project/shell/terminal_ui.tscn"
# Viewport sizes of the default, smallest and a larger window, at the render
# density window.tscn sets.
const SIZES: Array[Vector2i] = [Vector2i(400, 200), Vector2i(107, 60), Vector2i(800, 450)]

var _report := Report.new()


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	for size in SIZES:
		await _check_size(size)
	_report.finish(self)


func _check_size(size: Vector2i) -> void:
	_report.section("a %dx%d viewport" % [size.x, size.y])
	var viewport := SubViewport.new()
	viewport.size = size
	root.add_child(viewport)
	var terminal: TerminalUi = load(TERMINAL_SCENE).instantiate()
	viewport.add_child(terminal)
	# Containers settle over a few frames.
	for i in 3:
		await process_frame

	var input := terminal.input_line.get_global_rect()
	var output := terminal.output_display.get_global_rect()
	_report.check("keeps the input line below the top edge", input.position.y >= 0.0,
			str(input))
	_report.check("keeps the output above the bottom edge", output.end.y <= size.y,
			str(output))
	_report.near("output bottom", output.end.y, size.y, 0.5)
	viewport.queue_free()
