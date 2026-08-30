extends SceneTree

## Verifies that long application metadata stays inside the menu viewport and
## that rows keep the same padding with or without category text.
##
## Run with:
##   godot --headless --xr-mode off --path . \
##       --script res://tests/app_menu_layout_test.gd

const Report := preload("res://tests/support/report.gd")

const VIEWPORT_SIZE := Vector2i(450, 375)
const CONTENT_MARGIN := 40.0
const ROW_PADDING := 20.0
const LONG_NAME := "An intentionally extremely long application name that cannot fit in one row"
const LONG_CATEGORIES := "Utility;AudioVideo;Development;AnExtremelyLongCategoryName;"

var _report := Report.new()
var _fixture_dir := ""


func _initialize() -> void:
	_fixture_dir = OS.get_temp_dir().path_join(
			"standalone_launcher_app_menu_layout_test_%d" % OS.get_process_id())
	DirAccess.make_dir_recursive_absolute(_fixture_dir + "/applications")
	OS.set_environment(FileUtils.SHARE_DIR_ENV, _fixture_dir)

	var viewport := SubViewport.new()
	viewport.size = VIEWPORT_SIZE
	root.add_child(viewport)

	var menu = load("res://project/launch_service/application_menu.tscn").instantiate()
	viewport.add_child(menu)
	await process_frame

	var apps: Dictionary[String, Dictionary] = {
		LONG_NAME: {"Exec": "/bin/true", "Categories": LONG_CATEGORIES},
		"Short": {"Exec": "/bin/true"},
	}
	menu.populate_apps(apps)
	await process_frame
	await process_frame

	var scroll: ScrollContainer = menu.scroll_container
	var list: VBoxContainer = menu.apps_list
	var rows := _live_rows(list)

	_report.section("list width")
	_report.check("the list uses EXPAND_FILL",
			list.size_flags_horizontal == Control.SIZE_EXPAND_FILL,
			str(list.size_flags_horizontal))
	_report.near("the scroll area fits between the outer margins", scroll.size.x,
			float(VIEWPORT_SIZE.x) - CONTENT_MARGIN)
	_report.near("the list begins at the scroll area's left edge", list.position.x, 0.0)
	_report.near("the list fills the scroll area", list.size.x, scroll.size.x)
	_report.check("both fixture applications have rows", rows.size() == apps.size(),
			str(rows.size()))
	for row in rows:
		_report.near("each row fills the list", row.size.x, list.size.x)

	_report.section("bounded labels")
	var labels := _descendant_labels(list)
	_report.check("the name and categories labels were found", labels.size() == 3,
			str(labels.size()))
	for label in labels:
		_report.check("'%s' clips overflowing text" % label.text, label.clip_text)
		_report.check("'%s' trims with an ellipsis" % label.text,
				label.text_overrun_behavior == TextServer.OVERRUN_TRIM_ELLIPSIS,
				str(label.text_overrun_behavior))
		_report.check("'%s' expands to the row width" % label.text,
				label.size_flags_horizontal == Control.SIZE_EXPAND_FILL,
				str(label.size_flags_horizontal))
	_report.check("the long name no longer sets the list width",
			list.get_combined_minimum_size().x < scroll.size.x,
			str(list.get_combined_minimum_size().x))

	_report.section("consistent row padding")
	for row in rows:
		var hbox := _row_hbox(row)
		var right_spacer: Control = hbox.get_child(hbox.get_child_count() - 1) if hbox else null
		_report.check("each row ends with a spacer", right_spacer != null)
		if right_spacer:
			_report.near("each row has the same right padding",
					right_spacer.custom_minimum_size.x, ROW_PADDING)

	viewport.queue_free()
	await process_frame
	DirAccess.remove_absolute(_fixture_dir + "/applications")
	DirAccess.remove_absolute(_fixture_dir)
	OS.unset_environment(FileUtils.SHARE_DIR_ENV)
	_report.finish(self)


func _live_rows(list: VBoxContainer) -> Array:
	var rows := []
	for child in list.get_children():
		if not child.is_queued_for_deletion():
			rows.append(child)
	return rows


func _descendant_labels(node: Node) -> Array[Label]:
	var labels: Array[Label] = []
	for child in node.get_children():
		if child is Label:
			labels.append(child)
		labels.append_array(_descendant_labels(child))
	return labels


func _row_hbox(row: Node) -> HBoxContainer:
	for child in row.get_children():
		if child is HBoxContainer:
			return child
	return null
