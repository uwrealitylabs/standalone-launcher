extends SceneTree

## Verifies IconTheme's ranking against icon trees written to user:// at run
## time.
##
## Run with:
##   godot --headless --xr-mode off --path . \
##       --script res://tests/icon_theme_check.gd
##
## --xr-mode off is required: without it a modal OpenXR alert hangs the run.
##
## Every check builds its own share root. IconTheme rebuilds its index when the
## root changes, so a fresh root is what gives a check a fresh index; reusing
## one root across checks would serve the first check's answers to the rest.
##
## Which file won is read off the texture's side length rather than an internal
## path, so each fixture is written at a side that identifies it.
##
## The fall-through check deliberately writes an undecodable image; the decode
## error in the log is expected output, not a failure.

const Report := preload("res://tests/support/report.gd")

var _fixture_dir := ""
var _report := Report.new()


func _initialize() -> void:
	_fixture_dir = OS.get_user_data_dir() + "/icon_theme_check"
	_teardown()  # a previous aborted run may have left the directory behind

	_check_beyond_the_old_lookup()
	_check_source_precedence()
	_check_size_preference()
	_check_scale_preference()
	_check_extension_tie_break()
	_check_undecodable_falls_through()
	_check_xpm_never_returned()
	_check_absolute_path()
	_check_misses()
	_check_index_records_context_and_scale()
	_check_root_change_invalidates()

	_teardown()
	_report.finish(self)


## The three dimensions the old hardcoded lookup could not reach: a size other
## than 48, a context other than apps, and a theme other than hicolor.
func _check_beyond_the_old_lookup() -> void:
	_report.section("beyond the old lookup")
	_share("dimensions", {
		"icons/hicolor/128x128/apps/big.png": 7,
		"icons/hicolor/48x48/places/placed.png": 8,
		"icons/Adwaita/48x48/apps/elsewhere.png": 9,
		"icons/Adwaita/48x48/legacy/both.png": 10,
	})
	_report.check("a 128-only icon resolves", _side("big") == 7, str(_side("big")))
	_report.check("a non-apps context resolves", _side("placed") == 8, str(_side("placed")))
	_report.check("a non-hicolor theme resolves",
			_side("elsewhere") == 9, str(_side("elsewhere")))
	_report.check("a non-hicolor theme in a non-apps context resolves",
			_side("both") == 10, str(_side("both")))


## Source fidelity beats size fidelity: hicolor, then pixmaps, then any other
## theme, even when a later source has the better-sized file.
##
## No corpus reaches this, so these checks are the only guard on the ordering.
func _check_source_precedence() -> void:
	_report.section("source precedence")

	# The cross-dimensional case. Both single-dimension checks above still pass
	# under a ranking that puts size first, which would invert this one.
	_share("cross", {
		"icons/hicolor/128x128/apps/foo.png": 7,
		"icons/Adwaita/48x48/apps/foo.png": 9,
	})
	_report.check("hicolor at 128 beats another theme at exactly 48",
			_side("foo") == 7, str(_side("foo")))

	_share("all_three", {
		"icons/hicolor/16x16/apps/bar.png": 3,
		"pixmaps/bar.png": 5,
		"icons/Adwaita/48x48/apps/bar.png": 7,
	})
	_report.check("hicolor outranks pixmaps and other themes",
			_side("bar") == 3, str(_side("bar")))

	_share("no_hicolor", {
		"pixmaps/baz.png": 5,
		"icons/Adwaita/48x48/apps/baz.png": 7,
	})
	_report.check("pixmaps outranks other themes",
			_side("baz") == 5, str(_side("baz")))

	# Alphabetical order between themes is only a tie-break, but it has to be
	# stable or the same tree resolves differently between runs.
	_share("two_themes", {
		"icons/Adwaita/48x48/apps/qux.png": 5,
		"icons/breeze/48x48/apps/qux.png": 7,
	})
	_report.check("themes are ordered deterministically",
			_side("qux") == 5, str(_side("qux")))


## Within one source: exact, then scalable, then nearest larger, then nearest
## smaller, then a size directory that means nothing to us.
func _check_size_preference() -> void:
	_report.section("size preference")

	_share("exact", {
		"icons/hicolor/48x48/apps/a.png": 4,
		"icons/hicolor/scalable/apps/a.svg": 6,
		"icons/hicolor/64x64/apps/a.png": 8,
	})
	_report.check("an exact size wins", _side("a") == 4, str(_side("a")))

	# Again the loser is the .png, so that the extension tie-break cannot be
	# what produces the right answer.
	_share("exact_over_scalable", {
		"icons/hicolor/48x48/apps/a2.svg": 4,
		"icons/hicolor/scalable/apps/a2.png": 6,
	})
	_report.check("an exact size beats scalable", _side("a2") == 4, str(_side("a2")))

	_share("scalable", {
		"icons/hicolor/scalable/apps/b.svg": 6,
		"icons/hicolor/64x64/apps/b.png": 8,
	})
	_report.check("scalable beats a raster that is not exact",
			_side("b") == 6, str(_side("b")))

	_share("larger", {
		"icons/hicolor/64x64/apps/c.png": 8,
		"icons/hicolor/32x32/apps/c.png": 4,
	})
	_report.check("larger beats smaller", _side("c") == 8, str(_side("c")))

	_share("nearest", {
		"icons/hicolor/64x64/apps/d.png": 8,
		"icons/hicolor/256x256/apps/d.png": 12,
	})
	_report.check("the nearest larger size wins", _side("d") == 8, str(_side("d")))

	_share("unknown_dir", {
		"icons/hicolor/symbolic/apps/e.png": 4,
		"icons/hicolor/64x64/apps/e.png": 8,
	})
	_report.check("an unreadable size directory ranks last",
			_side("e") == 8, str(_side("e")))


## 48x48@2 is a logical 48 drawn for a 2x display, so it loses to a plain 48 at
## the same size rather than being treated as some other size.
##
## No corpus reaches this either: hicolor's index.theme declares @2 directories
## but none exist on disk.
func _check_scale_preference() -> void:
	_report.section("scale preference")
	# The scaled file is the .png deliberately: png beats svg further down the
	# ranking, so only the scale rule can pick the unscaled one here. Two .png
	# files would be decided by the path tie-break, which favours "48x48/" over
	# "48x48@2/" on its own and would pass with the scale rule deleted.
	_share("scale", {
		"icons/hicolor/48x48/apps/f.svg": 4,
		"icons/hicolor/48x48@2/apps/f.png": 6,
	})
	_report.check("unscaled beats scaled at the same size",
			_side("f") == 4, str(_side("f")))

	_share("only_scaled", {
		"icons/hicolor/48x48@2/apps/g.png": 6,
		"icons/hicolor/16x16/apps/g.png": 3,
	})
	_report.check("a scaled directory is still the right size",
			_side("g") == 6, str(_side("g")))


func _check_extension_tie_break() -> void:
	_report.section("extension tie-break")
	# The two sit in different contexts, which does not affect ranking, so that
	# the png sorts after the svg by path. Side by side in one directory the
	# path tie-break picks "h.png" over "h.svg" on its own, and the check would
	# pass with the extension rule deleted.
	_share("extension", {
		"icons/hicolor/48x48/status/h.png": 4,
		"icons/hicolor/48x48/apps/h.svg": 9,
	})
	_report.check("png is preferred over svg at the same rank",
			_side("h") == 4, str(_side("h")))


## Ranking is a preference, not a commitment: the best-ranked file must not
## shadow a lower-ranked one when it will not decode.
func _check_undecodable_falls_through() -> void:
	_report.section("undecodable candidate")
	_share("undecodable", {
		"icons/hicolor/48x48/apps/i.png": 0,
		"icons/hicolor/scalable/apps/i.svg": 6,
	})
	_report.check("a file that will not decode is skipped",
			_side("i") == 6, str(_side("i")))


## .xpm is all over /usr/share/pixmaps and Godot cannot read any of it, so it
## must never be offered as a candidate.
func _check_xpm_never_returned() -> void:
	_report.section("xpm")
	_share("xpm", {
		"pixmaps/j.xpm": 4,
		"pixmaps/k.xpm": 4,
		"icons/hicolor/16x16/apps/k.png": 3,
	})
	_report.check("an xpm-only name does not resolve", _side("j") == -1, str(_side("j")))
	_report.check("an xpm does not shadow a readable file",
			_side("k") == 3, str(_side("k")))
	# Asserted on the index, not the outcome: an indexed xpm resolves the same
	# way because it never decodes, so only the index shows it was left out --
	# which is the point, since every indexed xpm is a decode error in the log.
	_report.check("an xpm is not indexed at all",
			not IconTheme._index.has("j"), str(IconTheme._index.keys()))


## An absolute Icon= means that path. It is not relative to the share root, so
## the override does not redirect it and the index does not shadow it.
func _check_absolute_path() -> void:
	_report.section("absolute path")
	var outside := _fixture_dir + "/outside.png"
	_write_image(outside, 11)
	_share("absolute", {"icons/hicolor/48x48/apps/outside.png": 4})

	_report.check("an absolute path resolves from outside the share root",
			_side(outside) == 11, str(_side(outside)))
	_report.check("an absolute path is not looked up in the index",
			_side("outside") == 4, str(_side("outside")))
	_report.check("an absolute path that is not there is null",
			_side(_fixture_dir + "/nothing.png") == -1)


func _check_misses() -> void:
	_report.section("misses")
	_share("misses", {"icons/hicolor/48x48/apps/l.png": 4})
	_report.check("an unknown name is null", _side("absent") == -1, str(_side("absent")))
	_report.check("an empty name is null", _side("") == -1, str(_side("")))
	# A near miss must not resolve: names are matched whole, not by prefix.
	_report.check("a partial name is null", _side("l.pn") == -1, str(_side("l.pn")))


## Context and scale do not affect today's ranking, so nothing else would catch
## them being parsed wrong.
func _check_index_records_context_and_scale() -> void:
	_report.section("index fields")
	_share("fields", {
		"icons/hicolor/48x48/stock/chart/m.png": 4,
		"icons/hicolor/32x32@3/apps/n.png": 5,
		"pixmaps/o.png": 6,
	})
	_side("m")  # resolving anything is what builds the index

	var nested: IconTheme.Candidate = IconTheme._index["m"][0]
	_report.check("a nested context is kept whole",
			nested.context == "stock/chart", nested.context)
	_report.check("a nested context still carries its size",
			nested.size == 48 and nested.scale == 1,
			"%d@%d" % [nested.size, nested.scale])

	var scaled: IconTheme.Candidate = IconTheme._index["n"][0]
	_report.check("size and scale are separate",
			scaled.size == 32 and scaled.scale == 3,
			"%d@%d" % [scaled.size, scaled.scale])

	var pixmap: IconTheme.Candidate = IconTheme._index["o"][0]
	_report.check("a pixmap has no theme, context or size",
			pixmap.theme == IconTheme.UNTHEMED and pixmap.context == ""
					and pixmap.size_kind == IconTheme.SizeKind.UNKNOWN)


## The caches are only valid for the root they were walked from. A root-blind
## cache would keep serving the first root's answers, including its misses.
func _check_root_change_invalidates() -> void:
	_report.section("root change")
	var first := _share("root_a", {"icons/hicolor/48x48/apps/p.png": 4})
	_report.check("the first root resolves", _side("p") == 4, str(_side("p")))
	_report.check("a name only the second root has misses",
			_side("q") == -1, str(_side("q")))

	_share("root_b", {
		"icons/hicolor/48x48/apps/p.png": 8,
		"icons/hicolor/48x48/apps/q.png": 9,
	})
	_report.check("the second root wins the same name", _side("p") == 8, str(_side("p")))
	_report.check("a cached miss is not carried over", _side("q") == 9, str(_side("q")))

	OS.set_environment(FileUtils.SHARE_DIR_ENV, first)
	_report.check("switching back restores the first root",
			_side("p") == 4 and _side("q") == -1, str(_side("p")))


## Side length of what `name` resolves to at `size`, or -1 when nothing does.
func _side(name: String, size: int = 48) -> int:
	var texture := IconTheme.load_icon(name, size)
	return -1 if texture == null else texture.get_width()


## Builds a share root under the fixture directory from `files`, a map of paths
## relative to that root onto the side length to write each at, and points
## SHARE_DIR_ENV at it. Returns the root.
func _share(name: String, files: Dictionary) -> String:
	var root := _fixture_dir + "/" + name
	_remove_tree(root)
	# Both trees exist even when a check populates neither, so that a walk over
	# an absent directory is never what a check is really measuring.
	DirAccess.make_dir_recursive_absolute(root + "/icons")
	DirAccess.make_dir_recursive_absolute(root + "/pixmaps")
	for relative in files:
		var path: String = root + "/" + relative
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		_write_image(path, files[relative])
	OS.set_environment(FileUtils.SHARE_DIR_ENV, root)
	return root


## Writes an image at `path` that decodes to `side` by `side`, in the format its
## extension names. A `side` of 0 writes bytes that are not an image at all.
func _write_image(path: String, side: int) -> void:
	if side == 0:
		var broken := FileAccess.open(path, FileAccess.WRITE)
		broken.store_string("not an image")
		broken.close()
		return

	match path.get_extension():
		"png":
			var image := Image.create_empty(side, side, false, Image.FORMAT_RGBA8)
			image.fill(Color.RED)
			image.save_png(path)
		"svg":
			var file := FileAccess.open(path, FileAccess.WRITE)
			file.store_string(('<svg xmlns="http://www.w3.org/2000/svg" width="%d" '
					+ 'height="%d" viewBox="0 0 %d %d">'
					+ '<rect width="%d" height="%d" fill="red"/></svg>')
					% [side, side, side, side, side, side])
			file.close()
		"xpm":
			var file := FileAccess.open(path, FileAccess.WRITE)
			file.store_string('/* XPM */\nstatic char *x[] = {\n"1 1 1 1",\n'
					+ '"  c #FF0000",\n" "};\n')
			file.close()


## Deletes `path` and everything under it, at any depth.
func _remove_tree(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for sub in dir.get_directories():
		_remove_tree(path + "/" + sub)
	for f in dir.get_files():
		DirAccess.remove_absolute(path + "/" + f)
	DirAccess.remove_absolute(path)


func _teardown() -> void:
	OS.unset_environment(FileUtils.SHARE_DIR_ENV)
	_remove_tree(_fixture_dir)
