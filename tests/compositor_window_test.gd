extends SceneTree

## Verifies Milestone 5: an SWindow backed by a fixed-size compositor surface.
##
##   - the window opens at the layout default size with the screen in place of its
##     Content viewport, the client asked for that size, and no resize handles;
##   - programmatic resize requests leave the size alone;
##   - off-headset, only virtual-keyboard keys reach the surface, not physical ones;
##   - keys and pointer reach the surface only while the window is focused, and a
##     press on the surface focuses the window;
##   - the solo tween's interaction lock cuts keys and pointer, ending a press;
##   - a suspended window's surface is hidden and takes no input;
##   - the size stays fixed through a solo cycle;
##   - closing waits for the screen to shut down, then frees the window.
##
## The screen gets a fake compositor with autostart off, as in
## compositor_keyboard_routing_test.gd, so no Wayland server starts on any host.
##
## Run with:
##   godot --headless --xr-mode off --path . \
##       --script res://tests/compositor_window_test.gd

const Report := preload("res://tests/support/report.gd")
const Fixtures := preload("res://tests/support/window_fixtures.gd")

const WM_SCENE := "res://project/windowing/window_manager.tscn"
const SCREEN_SCENE := "res://project/compositor/compositor_screen.tscn"
const EPS := 0.0001

const Type := XRToolsPointerEvent.Type


## Stands in for WaylandCompositor, logging every call in order.
class FakeCompositor:
	extends Node
	var calls: Array[String] = []

	func set_keyboard_focus(focused: bool) -> void:
		calls.append("focus %s" % focused)

	func set_toplevel_activated(activated: bool) -> void:
		calls.append("activated %s" % activated)

	func send_physical_key(_event: InputEventKey) -> void:
		calls.append("physical")

	func send_virtual_key(_event: InputEventKey) -> void:
		calls.append("virtual")

	func pointer_enter(_uv: Vector2) -> void:
		calls.append("enter")

	func pointer_motion(_uv: Vector2) -> void:
		calls.append("motion")

	func pointer_leave() -> void:
		calls.append("leave")

	func send_button(_button: int, pressed: bool) -> void:
		calls.append("down" if pressed else "up")

	func get_stats() -> Dictionary:
		return {}

	func stop() -> void:
		calls.append("stop")

	## Returns the calls since the last take and forgets them.
	func take() -> Array[String]:
		var out := calls.duplicate()
		calls.clear()
		return out


var _report := Report.new()


func _initialize() -> void:
	var wm: WindowManager = (load(WM_SCENE) as PackedScene).instantiate()
	root.add_child(wm)
	await process_frame

	var screen := (load(SCREEN_SCENE) as PackedScene).instantiate() as MeshInstance3D
	screen.autostart = false
	var win := wm.create_compositor_window(screen)
	var fake := FakeCompositor.new()
	screen.add_child(fake)
	screen._compositor = fake
	screen._on_surface_mapped(Vector2i(640, 360))
	# Stands in for the first frame binding a texture.
	screen.visible = true
	await physics_frame

	_check_opened(wm, win, screen, fake)
	_check_physical_keys_off_headset(wm, screen, fake)
	_check_resize_ignored(wm, win, screen)
	await _check_focus_gate(wm, win, screen, fake)
	await _check_interaction_lock(win, screen, fake)
	await _check_suspension(wm, win, screen, fake)
	await _check_solo_cycle(wm, win, screen)
	await _check_close(wm, win, fake)
	_report.finish(self)


func _check_opened(wm: WindowManager, win: SWindow, screen: MeshInstance3D,
		fake: FakeCompositor) -> void:
	_report.section("opening")
	_report.check("the window opened in LEFT and is focused",
			win != null and wm.slots[WindowManager.Slot.LEFT] == win
			and wm.focused_window == win)
	var size := wm.default_size()
	_report.near("content width is the layout default", win.content_size.x, size.x)
	_report.near("content height is the layout default", win.content_size.y, size.y)
	_report.check("the screen sits under the window's Surface node",
			screen.get_parent() == win.get_node_or_null("Surface"))
	_report.check("the Content viewport is hidden", not win.content_3d.visible)
	var quad := (screen.mesh as QuadMesh).size
	_report.check("the quad is the content size", quad.is_equal_approx(size), str(quad))
	var expected := Vector2i((size * win.PIXELS_PER_UNIT).round())
	_report.check("the client is asked for the content size at the window's density",
			screen.initial_size == expected, "%s vs %s" % [screen.initial_size, expected])
	_report.check("there are no resize handles",
			win.get_node_or_null("ResizeHandles") == null
			and win.get_node_or_null("ResizeAffordances") == null
			and Fixtures.handle(win, "BR") == null)
	_report.check("the mapped surface takes focus as the focused window",
			fake.take() == ["focus true", "activated true"])


## Runs without OpenXR, so the window takes keys only from the virtual keyboard.
## The later sections call _unhandled_key_input directly to cover the focus gate
## that a headset run keeps.
func _check_physical_keys_off_headset(wm: WindowManager, screen: MeshInstance3D,
		fake: FakeCompositor) -> void:
	_report.section("physical keyboard off-headset")
	_report.check("OpenXR is not active in this run", not XRUtils.is_openxr_active())
	_report.check("the screen does not process physical keys",
			not screen.is_processing_unhandled_key_input())
	root.push_input(_key())
	_report.check("a physical key through the viewport does not reach the surface",
			fake.take().is_empty())
	wm._on_key_pressed(_key())
	_report.check("a virtual-keyboard key does", fake.take() == ["virtual"])
	# Control: the same push does arrive once processing is on, so the empty
	# result above is the gate, not a push that never dispatched.
	screen.set_process_unhandled_key_input(true)
	root.push_input(_key())
	_report.check("control: with processing on, the push reaches the surface",
			fake.take() == ["physical"])
	screen.set_process_unhandled_key_input(false)


func _check_resize_ignored(wm: WindowManager, win: SWindow, screen: MeshInstance3D) -> void:
	_report.section("programmatic resize is ignored")
	var before := win.content_size
	win.resize(before * 0.6)
	wm.resize_window(win, before * 1.3)
	win._commit_requested_size(Vector2(0.5, 0.5))
	_report.check("content_size is unchanged", win.content_size.is_equal_approx(before),
			str(win.content_size))
	_report.check("the presented size is unchanged", win._active_size.is_equal_approx(before))
	_report.check("the quad is unchanged",
			(screen.mesh as QuadMesh).size.is_equal_approx(before))


func _check_focus_gate(wm: WindowManager, win: SWindow, screen: MeshInstance3D,
		fake: FakeCompositor) -> void:
	_report.section("input follows window focus")
	screen._unhandled_key_input(_key())
	wm._on_key_pressed(_key())
	_report.check("focused: physical and virtual keys reach the surface",
			fake.take() == ["physical", "virtual"])

	var terminal: SWindow = wm.slots[WindowManager.Slot.RIGHT]
	wm.focus(terminal)
	_report.check("unfocused: keyboard focus and activated clear",
			fake.take() == ["focus false", "activated false"])
	screen._unhandled_key_input(_key())
	wm._on_key_pressed(_key())
	_report.check("unfocused: no key reaches the surface", fake.take().is_empty())

	# A pinch on the surface of the unfocused window focuses it and clicks.
	screen.pointer_event.emit(_event(Type.ENTERED, screen, Vector2(0.3, 0.4)))
	screen.pointer_event.emit(_event(Type.PRESSED, screen, Vector2(0.3, 0.4)))
	_report.check("a press on the surface focuses the window", wm.focused_window == win)
	_report.check("the pointer entered and pressed after focus returned",
			fake.take() == ["enter", "focus true", "activated true", "down"])
	screen.pointer_event.emit(_event(Type.RELEASED, screen, Vector2(0.3, 0.4)))
	_report.check("the release reaches the surface", fake.take() == ["up"])
	await physics_frame


func _check_interaction_lock(win: SWindow, screen: MeshInstance3D,
		fake: FakeCompositor) -> void:
	_report.section("the interaction lock")
	screen.pointer_event.emit(_event(Type.PRESSED, screen, Vector2(0.5, 0.5)))
	fake.take()
	win.set_interaction_locked(true)
	_report.check("locking ends the press and takes the pointer and keys off",
			fake.take() == ["up", "leave", "focus false"])
	await physics_frame
	_report.check("the collider is disabled", _shape(screen).disabled)
	screen.pointer_event.emit(_event(Type.MOVED, screen, Vector2(0.6, 0.6)))
	screen.pointer_event.emit(_event(Type.RELEASED, screen, Vector2(0.6, 0.6)))
	screen._unhandled_key_input(_key())
	_report.check("locked: pointer and keys are dropped", fake.take().is_empty())

	win.set_interaction_locked(false)
	await physics_frame
	_report.check("unlocking restores keys, still activated",
			fake.take() == ["focus true"])
	_report.check("the collider is enabled again", not _shape(screen).disabled)
	screen.pointer_event.emit(_event(Type.ENTERED, screen, Vector2(0.5, 0.5)))
	_report.check("a hand entering again reaches the surface", fake.take() == ["enter"])
	screen.pointer_event.emit(_event(Type.EXITED, screen, Vector2(0.5, 0.5)))
	fake.take()


func _check_suspension(wm: WindowManager, win: SWindow, screen: MeshInstance3D,
		fake: FakeCompositor) -> void:
	_report.section("suspended behind another window's solo")
	var terminal: SWindow = wm.slots[WindowManager.Slot.RIGHT]
	wm.solo_transition_duration = 0.0
	screen.pointer_event.emit(_event(Type.ENTERED, screen, Vector2(0.5, 0.5)))
	fake.take()
	wm.enter_solo(terminal)
	await physics_frame
	_report.check("the surface is hidden", not screen.is_visible_in_tree())
	_report.check("the collider is disabled", _shape(screen).disabled)
	var calls := fake.take()
	_report.check("the pointer left and focus went to the soloed window",
			calls == ["focus false", "activated false", "leave"], str(calls))
	screen.pointer_event.emit(_event(Type.ENTERED, screen, Vector2(0.5, 0.5)))
	screen._unhandled_key_input(_key())
	wm._on_key_pressed(_key())
	_report.check("suspended: no input reaches the surface", fake.take().is_empty())

	wm.exit_solo()
	await physics_frame
	_report.check("the surface shows again", screen.is_visible_in_tree())
	_report.check("the collider is enabled again", not _shape(screen).disabled)
	wm.focus(win)
	fake.take()


func _check_solo_cycle(wm: WindowManager, win: SWindow, screen: MeshInstance3D) -> void:
	_report.section("fixed size through a solo cycle")
	var size := win.content_size
	var docked := win.transform
	wm.solo_transition_duration = 0.1
	var sizes: Array[Vector2] = []
	wm.enter_solo(win)
	while wm._solo_state == WindowManager.Presentation.ENTERING:
		await process_frame
		sizes.append(win._active_size)
	_report.check("solo entered", wm._solo_state == WindowManager.Presentation.SOLO)
	_report.check("the window moved to CENTRE",
			win.transform.origin.is_equal_approx(
					wm.slot_transform(WindowManager.Slot.CENTRE).origin))
	_report.check("the solo size is the content size",
			win.current_solo_size.is_equal_approx(size), str(win.current_solo_size))
	wm.exit_solo()
	while wm._solo_state == WindowManager.Presentation.EXITING:
		await process_frame
		sizes.append(win._active_size)
	_report.check("solo exited back to LEFT",
			wm._solo_state == WindowManager.Presentation.DOCKED
			and win.transform.is_equal_approx(docked))
	_report.check("the tween sampled frames", sizes.size() >= 2, str(sizes.size()))
	_report.check("every presented size was the content size",
			sizes.all(func(s: Vector2) -> bool: return s.is_equal_approx(size)))
	_report.check("content_size and the quad are unchanged",
			win.content_size.is_equal_approx(size)
			and (screen.mesh as QuadMesh).size.is_equal_approx(size))


func _check_close(wm: WindowManager, win: SWindow, fake: FakeCompositor) -> void:
	_report.section("closing")
	# The fake is freed with the window; keep its log.
	var calls := fake.calls
	win.close()
	_report.check("the slot is released at once", wm.slots[WindowManager.Slot.LEFT] == null)
	_report.check("the window hides while its screen shuts down",
			is_instance_valid(win) and not win.visible)
	win.close()
	await process_frame
	await process_frame
	_report.check("the screen stopped its compositor", calls.count("stop") == 1,
			str(calls))
	_report.check("the window was freed", not is_instance_valid(win))


func _shape(screen: MeshInstance3D) -> CollisionShape3D:
	return screen.get_node("StaticBody3D/CollisionShape3D") as CollisionShape3D


## An event with no pointer at surface `uv`, as a hand hitting the quad there.
func _event(type: int, screen: MeshInstance3D, uv: Vector2) -> XRToolsPointerEvent:
	var quad := (screen.mesh as QuadMesh).size
	var local := Vector3((uv.x - 0.5) * quad.x, (0.5 - uv.y) * quad.y, 0.0)
	return Fixtures.event_at(type, screen, screen.to_global(local))


func _key() -> InputEventKey:
	var key := InputEventKey.new()
	key.keycode = KEY_A
	key.physical_keycode = KEY_A
	key.pressed = true
	return key
