extends RefCounted
class_name WaylandPointerRouter

## Reduces hand pointers to the one pointer a Wayland seat has, driving [member sink]
## with the [WaylandCompositor] input API. The first hovering hand owns it; another
## hand's press takes it only from an unpressed owner, whose exit hands it to the next
## hovering hand. It leaves when no hand hovers. Pinch is the left button.

## Receives the Wayland pointer calls. Null drops them while state still tracks.
var sink: Object = null

# Hovering hands, in the order they entered, to their last UV. Dictionaries keep
# insertion order, so the first key is the next owner after a handoff.
var _hovering: Dictionary = {}
var _owner: Object = null
var _owner_pressed := false
# Whether the Wayland pointer is on the surface, and the UV it was last sent.
var _entered := false
var _sent_uv := Vector2.ZERO


## Routes one pointer event. `uv` is the event position in surface UV. It reaches
## the seat outside 0..1 only during the owner's pressed drag; any other motion is
## clamped onto the surface.
func handle(pointer: Object, type: int, uv: Vector2) -> void:
	match type:
		XRToolsPointerEvent.Type.ENTERED:
			_hovering[pointer] = uv
			if _owner == null:
				_owner = pointer
			if pointer == _owner:
				_move_to(uv)
		XRToolsPointerEvent.Type.MOVED:
			if not _hovering.has(pointer):
				return
			_hovering[pointer] = uv
			if pointer == _owner:
				_move_to(uv)
		XRToolsPointerEvent.Type.PRESSED:
			if not _hovering.has(pointer):
				return
			_hovering[pointer] = uv
			if pointer != _owner:
				if _owner_pressed:
					return
				_owner = pointer
			# A Wayland button carries no position: move first, so a claiming
			# hand's click lands where it is, not where the old owner was.
			_move_to(uv)
			_owner_pressed = true
			_send("send_button", [MOUSE_BUTTON_LEFT, true])
		XRToolsPointerEvent.Type.RELEASED:
			if pointer != _owner or not _owner_pressed:
				return
			_move_to(uv)
			_release_button()
		XRToolsPointerEvent.Type.EXITED:
			if not _hovering.has(pointer):
				return
			_hovering.erase(pointer)
			if pointer != _owner:
				return
			# HandPointer never exits mid-press; end any press rather than
			# leave the client holding a button.
			if _owner_pressed:
				_release_button()
			_owner = null if _hovering.is_empty() else _hovering.keys()[0]
			if _owner == null:
				_entered = false
				_send("pointer_leave", [])
			else:
				_move_to(_hovering[_owner])


## Ends any press and takes the pointer off the surface, then forgets every hand,
## for when the surface stops taking pointer input while it stays mapped. A hand
## counts again only from its next ENTERED.
func cancel() -> void:
	if _owner_pressed:
		_release_button()
	if _entered:
		_send("pointer_leave", [])
	reset()


## Forgets every hand without sending anything, for when the surface goes away
## and the bridge has already cleared its own pointer focus.
func reset() -> void:
	_hovering.clear()
	_owner = null
	_owner_pressed = false
	_entered = false


## The hand that currently owns the Wayland pointer, or null.
func get_pointer_owner() -> Object:
	return _owner


## Moves the seat pointer to `uv`, which must be the owner's position.
func _move_to(uv: Vector2) -> void:
	# Only a press's implicit grab may leave the surface: a refused pinch still
	# reports points past the edge, and can inherit ownership while pinched.
	if not _owner_pressed:
		uv = uv.clamp(Vector2.ZERO, Vector2.ONE)
	if not _entered:
		_entered = true
		_sent_uv = uv
		_send("pointer_enter", [uv])
	elif uv != _sent_uv:
		_sent_uv = uv
		_send("pointer_motion", [uv])


func _release_button() -> void:
	_owner_pressed = false
	_send("send_button", [MOUSE_BUTTON_LEFT, false])


func _send(method: StringName, args: Array) -> void:
	if sink != null:
		sink.callv(method, args)
