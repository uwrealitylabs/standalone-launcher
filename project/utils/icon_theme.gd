class_name IconTheme

## Resolves a .desktop `Icon=` value against the installed icon tree.
##
## This is deliberately not the freedesktop icon theme algorithm. That algorithm
## is driven by a selected theme, from which `Inherits`, the per-directory size
## rules and the hicolor fallback all follow; the launcher has no theme selector
## and no state to drive it with. Instead every icon present under
## [method FileUtils.share_dir] is indexed by name, and [method load_icon] picks
## one by a fixed ranking.

## Extensions Godot can decode. `.xpm` is common in /usr/share/pixmaps but
## Image.load_from_file rejects it, so indexing it would only ever produce
## candidates that fail to load.
const LOADABLE_EXTENSIONS := ["png", "svg"]

## Pixel size assumed when a caller does not ask for one.
const DEFAULT_SIZE := 48

## Theme an application installs its own icon into.
const OWN_THEME := "hicolor"

## Stands in for <share>/pixmaps, which is not a theme directory.
const UNTHEMED := ""

## What a theme's size directory says about the icons inside it. UNKNOWN is an
## explicit last resort for names like "symbolic" or "scalable-up-to-32", so
## that an unrecognized directory is never given pseudo-size semantics.
enum SizeKind { RASTER, SCALABLE, UNKNOWN }


## One icon file on disk, with everything its path encodes.
##
## `context` and `scale` do not affect the current ranking. They are kept so the
## index can be asserted directly in tests and so a later preference does not
## have to change the index format.
class Candidate:
	var path: String
	var name: String
	var theme: String
	var context: String
	var size: int = 0
	var scale: int = 1
	var size_kind: SizeKind = SizeKind.UNKNOWN
	var extension: String


# The index is valid only for the share root it was walked from, so all three
# caches are discarded together when that root changes. Within one root the
# icon tree is assumed immutable -- see the note on load_icon.
static var _root := ""
static var _built := false
static var _index: Dictionary[String, Array] = {}
static var _resolved: Dictionary[String, String] = {}
static var _textures: Dictionary[String, Texture2D] = {}


## Returns the best icon named `icon_name` at `size`, or null if there is none.
##
## `icon_name` may be an absolute path, which is used as given. Otherwise it is
## matched against every icon under [method FileUtils.share_dir], preferring in
## order: hicolor, then unthemed pixmaps, then other themes alphabetically;
## within one of those, an exact size, then a scalable icon, then the nearest
## larger, then the nearest smaller; then unscaled over scaled, and png over svg.
##
## The icon tree is assumed not to change while a given share root is in use.
## Results are cached, misses included, until the root changes.
static func load_icon(icon_name: String, size: int = DEFAULT_SIZE) -> Texture2D:
	if icon_name.is_empty():
		return null

	_rebuild_if_root_changed()

	# An absolute path in a .desktop file means that path. It is not relative to
	# the share root, so WRL_SHARE_DIR does not redirect it.
	if icon_name.begins_with("/"):
		return _texture_for(icon_name)

	var key := "%s@%d" % [icon_name, size]
	if not _resolved.has(key):
		_resolved[key] = _resolve(icon_name, size)
	var path := _resolved[key]
	return null if path.is_empty() else _texture_for(path)


## Decodes `path`, or returns null when it is missing or not a format Godot
## reads. Textures are cached by path, so two names resolving to one file share
## a texture.
static func _texture_for(path: String) -> Texture2D:
	if _textures.has(path):
		return _textures[path]

	var texture: Texture2D = null
	if FileAccess.file_exists(path):
		var image := Image.load_from_file(path)
		if image != null:
			texture = ImageTexture.create_from_image(image)
	_textures[path] = texture
	return texture


## Returns the path of the best-ranked candidate that actually decodes, or "".
static func _resolve(icon_name: String, size: int) -> String:
	if not _index.has(icon_name):
		return ""

	var candidates: Array = _index[icon_name].duplicate()
	candidates.sort_custom(func(a: Candidate, b: Candidate) -> bool:
			return _is_better(a, b, size))

	# A candidate that will not decode must not shadow a lower-ranked one that
	# will, so the ranking is a preference rather than a commitment.
	for candidate in candidates:
		if _texture_for(candidate.path) != null:
			return candidate.path
	return ""


## True when `a` should be preferred over `b` for a request of `size`.
static func _is_better(a: Candidate, b: Candidate, size: int) -> bool:
	var a_source := _source_rank(a)
	var b_source := _source_rank(b)
	if a_source != b_source:
		return a_source < b_source

	# Themes past hicolor and pixmaps have no product-level preference between
	# them. Alphabetical order is only a tie-break and carries no meaning; it
	# runs ahead of size so one theme is exhausted before the next is tried.
	if a_source == 2 and a.theme != b.theme:
		return a.theme.naturalnocasecmp_to(b.theme) < 0

	var a_size := _size_rank(a, size)
	var b_size := _size_rank(b, size)
	if a_size != b_size:
		return a_size < b_size

	if a.size_kind == SizeKind.RASTER and b.size_kind == SizeKind.RASTER:
		var a_off := absi(a.size - size)
		var b_off := absi(b.size - size)
		if a_off != b_off:
			return a_off < b_off

	if a.scale != b.scale:
		return a.scale < b.scale
	if a.extension != b.extension:
		return a.extension == "png"
	return a.path < b.path


## Ranks where an icon came from: an app ships its own icon into hicolor or
## pixmaps, while any other theme carries a third-party replacement for the
## name. Source fidelity is preferred over a better-fitting size.
static func _source_rank(candidate: Candidate) -> int:
	if candidate.theme == OWN_THEME:
		return 0
	if candidate.theme == UNTHEMED:
		return 1
	return 2


static func _size_rank(candidate: Candidate, size: int) -> int:
	match candidate.size_kind:
		SizeKind.RASTER:
			if candidate.size == size:
				return 0
			# Downscaling reads better than upscaling, so larger beats smaller.
			return 2 if candidate.size > size else 3
		SizeKind.SCALABLE:
			return 1
		_:
			return 4


static func _rebuild_if_root_changed() -> void:
	var root := FileUtils.share_dir()
	if _built and root == _root:
		return

	_root = root
	_built = true
	_resolved.clear()
	_textures.clear()
	_index = _build_index(root)


## Walks the icon tree under `root` and groups every loadable file by name.
static func _build_index(root: String) -> Dictionary[String, Array]:
	var index: Dictionary[String, Array] = {}
	for path in FileUtils.get_all_file_paths(root + "/icons"):
		_add(index, _themed_candidate(path, root))
	for path in FileUtils.get_all_file_paths(root + "/pixmaps"):
		_add(index, _unthemed_candidate(path))
	return index


static func _add(index: Dictionary[String, Array], candidate: Candidate) -> void:
	if candidate == null:
		return
	if not index.has(candidate.name):
		index[candidate.name] = []
	index[candidate.name].append(candidate)


## Builds a candidate from <root>/icons/<theme>/<size>/<context>/<name>.<ext>,
## or null when the path is not that shape or not a loadable image.
static func _themed_candidate(path: String, root: String) -> Candidate:
	var parts := path.substr((root + "/icons/").length()).split("/")
	# theme, size directory and file name are the minimum a themed icon needs.
	if parts.size() < 3:
		return null

	var file := parts[parts.size() - 1]
	var extension := file.get_extension().to_lower()
	if not LOADABLE_EXTENSIONS.has(extension):
		return null

	var candidate := Candidate.new()
	candidate.path = path
	candidate.name = file.get_basename()
	candidate.theme = parts[0]
	# Contexts nest -- hicolor has 48x48/stock/chart -- so take everything
	# between the size directory and the file rather than a single component.
	candidate.context = "/".join(parts.slice(2, parts.size() - 1))
	candidate.extension = extension
	_apply_size_dir(candidate, parts[1])
	return candidate


## Builds a candidate from <root>/pixmaps/<name>.<ext>, which carries no theme,
## context or size, or null when it is not a loadable image.
static func _unthemed_candidate(path: String) -> Candidate:
	var file := path.get_file()
	var extension := file.get_extension().to_lower()
	if not LOADABLE_EXTENSIONS.has(extension):
		return null

	var candidate := Candidate.new()
	candidate.path = path
	candidate.name = file.get_basename()
	candidate.theme = UNTHEMED
	candidate.context = ""
	candidate.extension = extension
	return candidate


## Reads a theme's size directory: "48x48" is 48 at scale 1, "48x48@2" is a
## logical 48 drawn for a 2x display. Size and scale are separate dimensions, so
## a scaled directory is not recorded as some other size.
static func _apply_size_dir(candidate: Candidate, dir_name: String) -> void:
	var name := dir_name
	var at := name.find("@")
	if at != -1:
		candidate.scale = maxi(1, name.substr(at + 1).to_int())
		name = name.substr(0, at)

	if name == "scalable":
		candidate.size_kind = SizeKind.SCALABLE
		return

	var extents := name.split("x")
	if extents.size() == 2 and extents[0].is_valid_int() and extents[1].is_valid_int():
		candidate.size_kind = SizeKind.RASTER
		candidate.size = extents[0].to_int()
		return

	candidate.size_kind = SizeKind.UNKNOWN
