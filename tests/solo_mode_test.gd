extends SceneTree

## Verifies WindowManager's solo presentation: temporarily presenting one window
## alone at default_solo_size in the CENTRE slot, siblings suspended, animated by a
## manager-owned tween through a DOCKED/ENTERING/SOLO/EXITING state machine.
##
## Covers size/layout (content_size stays put while current_solo_size animates),
## focus and suspension (observable truth, not the addon's `enabled` flag), tween
## and transition safety (intermediate geometry, interaction locked throughout,
## exactly-once completion), the state-machine guards, stranded hover-affordance
## clearing, and programmatic close mid-transition.
##
## Run with:
##   godot --headless --xr-mode off --path . \
##       --script res://tests/solo_mode_test.gd
##
## --xr-mode off is required: without it a modal OpenXR alert hangs the run.
##
## The "Viewport Texture must be set to use it" errors are expected with no
## display server, not failures.

const Report := preload("res://tests/support/report.gd")
const Fixtures := preload("res://tests/support/window_fixtures.gd")

const WM_SCENE := "res://project/windowing/window_manager.tscn"
const EPS := 0.0001

var _report := Report.new()


func _initialize() -> void:
	await _check_enter_layout()
	await _check_focus_and_suspension()
	await _check_tween_safety()
	await _check_gesture_cancellation()
	await _check_state_machine_guards()
	await _check_hover_affordance_safety()
	await _check_close_mid_enter()
	await _check_close_mid_exit()
	await _check_contract_preservation()
	_report.finish(self)


# --- fixtures --------------------------------------------------------------

## A fresh manager with its two startup windows (menu CENTRE, terminal RIGHT)
## already open and one frame processed.
func _make_wm() -> WindowManager:
	var wm: WindowManager = (load(WM_SCENE) as PackedScene).instantiate()
	root.add_child(wm)
	await process_frame
	return wm


## Fills the LEFT slot so every slot is occupied, and returns the new window.
func _fill_left(wm: WindowManager) -> SWindow:
	var w := wm.create_window()
	await process_frame
	return w


func _free_wm(wm: WindowManager) -> void:
	wm.queue_free()
	await process_frame


## Whether both of `win`'s screen colliders (content and header) are disabled.
## Asserts the observable truth the addon actually toggles, whether the surface
## was hidden (suspension) or kept visible but disabled (interaction lock).
func _screens_disabled(win: SWindow) -> bool:
	var content: CollisionShape3D = win.content_3d.get_node("StaticBody3D/CollisionShape3D")
	var header: CollisionShape3D = win.header_3d.get_node("StaticBody3D/CollisionShape3D")
	return content.disabled and header.disabled


# --- size / layout ---------------------------------------------------------

## Enter preserves each window's slot and content_size, moves the soloed window to
## CENTRE at default_solo_size, and exit restores geometry from content_size and
## the transform from the window's own (unchanged) slot, discarding the solo size.
func _check_enter_layout() -> void:
	_report.section("enter/exit layout")
	var wm := await _make_wm()
	await _fill_left(wm)
	var CENTRE := WindowManager.Slot.CENTRE
	var RIGHT := WindowManager.Slot.RIGHT

	# Solo a non-centre window so the CENTRE-vs-slot transform test is meaningful.
	var win: SWindow = wm.slots[RIGHT]
	# Give it a docked size that differs from default_solo_size on both axes.
	win.resize(Vector2(1.6, 0.7))
	await process_frame
	var docked_size: Vector2 = win.content_size
	var slots_before := wm.slots.duplicate()
	var sibling_sizes := {}
	for other in wm.open_windows:
		if other != win:
			sibling_sizes[other] = other.content_size

	wm.solo_transition_duration = 0.03
	wm.enter_solo(win)
	await wm.solo_entered

	_report.check("state is SOLO after enter",
			wm._solo_state == WindowManager.Presentation.SOLO)
	_report.check("the soloed window is recorded", wm.soloed_window == win)
	_report.check("slot occupancy is unchanged", wm.slots == slots_before)
	_report.check("the soloed window's content_size is untouched",
			win.content_size.is_equal_approx(docked_size), str(win.content_size))
	_report.check("solo size settles at default_solo_size",
			win.current_solo_size.is_equal_approx(wm.default_solo_size),
			str(win.current_solo_size))
	_report.check("the soloed window sits at the CENTRE slot transform",
			win.transform.is_equal_approx(wm.slot_transform(CENTRE)))
	_report.check("displayed geometry follows the solo size",
			win._active_size.is_equal_approx(win.current_solo_size), str(win._active_size))

	# A solo resize moves only the live solo size.
	win.resize(Vector2(1.1, 0.6))
	await process_frame
	_report.check("solo resize changes current_solo_size",
			win.current_solo_size.is_equal_approx(Vector2(1.1, 0.6)), str(win.current_solo_size))
	_report.check("solo resize leaves content_size put",
			win.content_size.is_equal_approx(docked_size), str(win.content_size))
	_report.check("solo resize leaves slots put", wm.slots == slots_before)
	var siblings_intact := true
	for other in sibling_sizes:
		if not other.content_size.is_equal_approx(sibling_sizes[other]):
			siblings_intact = false
	_report.check("solo resize leaves the docked siblings' sizes put", siblings_intact)

	wm.exit_solo()
	await wm.solo_exited

	_report.check("state is DOCKED after exit",
			wm._solo_state == WindowManager.Presentation.DOCKED)
	_report.check("soloed_window is cleared after exit", wm.soloed_window == null)
	_report.check("exit discards the solo size", win.current_solo_size == Vector2.ZERO)
	_report.check("exit restores geometry from content_size",
			win._active_size.is_equal_approx(win.content_size), str(win._active_size))
	_report.check("exit restores the transform from the window's own slot",
			win.transform.is_equal_approx(wm.slot_transform(RIGHT)))

	# Re-entering re-initialises the solo size from default_solo_size.
	wm.enter_solo(win)
	await wm.solo_entered
	_report.check("re-entering re-inits from default_solo_size",
			win.current_solo_size.is_equal_approx(wm.default_solo_size),
			str(win.current_solo_size))

	await _free_wm(wm)


# --- focus / suspension ----------------------------------------------------

## Enter focuses the soloed window and suspends every sibling; suspension is
## asserted through observable truth (hidden, colliders disabled, redraw rested),
## never `content_3d.enabled`. set_suspended is idempotent; exit reactivates and
## keeps focus on the same window.
func _check_focus_and_suspension() -> void:
	_report.section("focus and suspension")
	var wm := await _make_wm()
	await _fill_left(wm)
	var RIGHT := WindowManager.Slot.RIGHT

	var win: SWindow = wm.slots[RIGHT]
	var siblings: Array[SWindow] = []
	for other in wm.open_windows:
		if other != win:
			siblings.append(other)

	wm.solo_transition_duration = 0.03
	wm.enter_solo(win)
	await wm.solo_entered

	_report.check("enter focuses the soloed window", wm.focused_window == win)

	var all_suspended := true
	var all_hidden := true
	var all_screens_off := true
	var all_handles_off := true
	var all_rested := true
	for other in siblings:
		if not other.is_suspended:
			all_suspended = false
		if other.content_3d.visible:
			all_hidden = false
		if not _screens_disabled(other):
			all_screens_off = false
		if not Fixtures.all_handles_disabled(other):
			all_handles_off = false
		var vp: SubViewport = Fixtures.viewport(other, "Content")
		if vp.render_target_update_mode != SubViewport.UPDATE_ONCE:
			all_rested = false
	_report.check("every sibling reports is_suspended", all_suspended)
	_report.check("every sibling's content surface is hidden", all_hidden)
	_report.check("every sibling's screen colliders are disabled", all_screens_off)
	_report.check("every sibling's resize handles are disabled", all_handles_off)
	_report.check("every suspended sibling rests its render target at UPDATE_ONCE",
			all_rested)

	# Idempotent: a second suspend on an already-suspended window is a no-op.
	var sib: SWindow = siblings[0]
	sib.set_suspended(true)
	_report.check("double-suspend stays suspended and hidden",
			sib.is_suspended and not sib.content_3d.visible)

	wm.exit_solo()
	await wm.solo_exited

	var all_active := true
	var all_visible := true
	for other in siblings:
		if other.is_suspended:
			all_active = false
		if not other.content_3d.visible:
			all_visible = false
	_report.check("exit clears is_suspended on every sibling", all_active)
	_report.check("exit makes every sibling visible again", all_visible)
	_report.check("normal unsolo keeps focus on the same window", wm.focused_window == win)

	# Idempotent restore: a second reactivate is a no-op.
	sib.set_suspended(false)
	_report.check("double-restore stays active and visible",
			not sib.is_suspended and sib.content_3d.visible)

	await _free_wm(wm)


# --- tween / transition safety ---------------------------------------------

## Across the enter tween: content_size never moves, the geometry is genuinely
## intermediate (strictly between start and target on both axes), interaction and
## handle collision stay disabled, and the committed size lands exactly on the
## render target.
func _check_tween_safety() -> void:
	_report.section("tween safety")
	var wm := await _make_wm()
	await _fill_left(wm)
	var RIGHT := WindowManager.Slot.RIGHT

	var win: SWindow = wm.slots[RIGHT]
	win.resize(Vector2(1.6, 0.7))  # both axes differ from default_solo_size
	await process_frame
	var start_size: Vector2 = win.content_size
	var target_size: Vector2 = wm.clamp_solo_size(win, wm.default_solo_size)

	# A generous duration plus manual stepping keeps the "midpoint" genuinely mid.
	wm.solo_transition_duration = 1.0
	wm.enter_solo(win)
	# Pause so only our custom_step advances it: a deterministic sample, never a
	# race with the idle-frame auto-processing.
	wm._solo_tween.pause()

	var content_held := true
	var strictly_between := true
	var locked_through := true
	for step in [0.25, 0.35, 0.3]:  # sums to 0.9 s of the 1.0 s tween
		wm._solo_tween.custom_step(step)
		if not win.content_size.is_equal_approx(start_size):
			content_held = false
		var s: Vector2 = win.current_solo_size
		if not (_strictly_between(s.x, start_size.x, target_size.x)
				and _strictly_between(s.y, start_size.y, target_size.y)):
			strictly_between = false
		if not (win._interaction_locked and _screens_disabled(win)
				and Fixtures.all_handles_disabled(win)):
			locked_through = false
	_report.check("content_size is unchanged on every tween frame", content_held)
	_report.check("mid-tween geometry is strictly between start and target",
			strictly_between, str(win.current_solo_size))
	_report.check("interaction and handles stay disabled throughout the tween",
			locked_through)
	_report.check("state is still ENTERING mid-tween",
			wm._solo_state == WindowManager.Presentation.ENTERING)

	# Drive it home; the final commit fires synchronously inside custom_step.
	wm._solo_tween.custom_step(0.2)
	_report.check("the tween completes to SOLO",
			wm._solo_state == WindowManager.Presentation.SOLO)
	_report.check("interaction is unlocked once solo", not win._interaction_locked)
	var expected := win._viewport_resolution(win.current_solo_size, win.PIXELS_PER_UNIT)
	_report.check("the committed render target matches the final solo size",
			win.content_3d.viewport_size.is_equal_approx(expected),
			"%s vs %s" % [win.content_3d.viewport_size, expected])

	await _free_wm(wm)


# --- gesture cancellation --------------------------------------------------

## Entering and exiting each cancel any active resize gesture, and a cancel resets
## the frozen width cap. A resize frame arriving after the cancel does not resurrect
## the old gesture and overwrite the programmatic result.
func _check_gesture_cancellation() -> void:
	_report.section("gesture cancellation")
	var wm := await _make_wm()
	await _fill_left(wm)
	var RIGHT := WindowManager.Slot.RIGHT

	var win: SWindow = wm.slots[RIGHT]
	# Start a real gesture through the handle, then enter solo.
	var handle := Fixtures.handle(win, "R")
	var grab := handle.global_position
	_press_handle(win, "R", grab)
	_report.check("the gesture started", win._resizing and wm.resizing_window == win)

	wm.solo_transition_duration = 0.03
	wm.enter_solo(win)
	_report.check("enter cancels the active gesture",
			not win._resizing and wm.resizing_window == null)
	_report.check("cancel resets the frozen width cap",
			is_equal_approx(win._resize_max_width, SWindow.MAX_CONTENT_SIZE.x))

	# A late resize frame must not resurrect the cancelled drag.
	var solo_size_before: Vector2 = win.current_solo_size
	win.update_resize(grab + Vector3(0.5, 0, 0))
	_report.check("a post-cancel resize frame is inert",
			win.current_solo_size.is_equal_approx(solo_size_before))
	await wm.solo_entered

	# Exit also cancels a gesture: start one on the soloed window, then exit.
	var solo_handle := Fixtures.handle(win, "R")
	_press_handle(win, "R", solo_handle.global_position)
	_report.check("a solo-time gesture started", win._resizing)
	wm.exit_solo()
	_report.check("exit cancels the active gesture",
			not win._resizing and wm.resizing_window == null)
	await wm.solo_exited

	await _free_wm(wm)


# --- state-machine guards --------------------------------------------------

## enter_solo is rejected unless DOCKED; exit_solo unless SOLO; and the
## zero-duration path commits synchronously without a tween or a hang.
func _check_state_machine_guards() -> void:
	_report.section("state-machine guards")
	var wm := await _make_wm()
	await _fill_left(wm)
	var RIGHT := WindowManager.Slot.RIGHT
	var LEFT := WindowManager.Slot.LEFT

	var win: SWindow = wm.slots[RIGHT]
	var other: SWindow = wm.slots[LEFT]

	# exit while DOCKED is a no-op.
	wm.exit_solo()
	_report.check("exit_solo while DOCKED is a no-op",
			wm._solo_state == WindowManager.Presentation.DOCKED and wm.soloed_window == null)

	# Zero-duration enter/exit commit synchronously (no tween, no await, no hang).
	wm.solo_transition_duration = 0.0
	wm.enter_solo(win)
	_report.check("zero-duration enter reaches SOLO synchronously",
			wm._solo_state == WindowManager.Presentation.SOLO and wm.soloed_window == win)
	_report.check("zero-duration enter builds no lingering tween", wm._solo_tween == null)

	# A second enter while SOLO is rejected; so is soloing a different window.
	wm.enter_solo(other)
	_report.check("enter_solo while SOLO is rejected (soloed window unchanged)",
			wm.soloed_window == win)

	wm.exit_solo()
	_report.check("zero-duration exit returns to DOCKED synchronously",
			wm._solo_state == WindowManager.Presentation.DOCKED and wm.soloed_window == null)
	_report.check("the exited window discards its solo size",
			win.current_solo_size == Vector2.ZERO)

	await _free_wm(wm)


# --- hover-affordance safety -----------------------------------------------

## A handle hovered when its collider is disabled never emits EXITED, so suspend
## and interaction-lock must clear the stranded affordance mark explicitly.
func _check_hover_affordance_safety() -> void:
	_report.section("hover-affordance safety")

	# Suspend path: hover a sibling's handle, then suspend it.
	var wm := await _make_wm()
	await _fill_left(wm)
	var RIGHT := WindowManager.Slot.RIGHT
	var sib: SWindow = wm.slots[WindowManager.Slot.LEFT]
	var win: SWindow = wm.slots[RIGHT]

	_hover_handle(sib, "R")
	_report.check("the hovered handle shows its affordance",
			sib._resize_affordances["R"].visible)
	wm.solo_transition_duration = 0.03
	wm.enter_solo(win)
	_report.check("suspend hides the stranded affordance mark",
			not sib._resize_affordances["R"].visible)
	_report.check("suspend clears the stranded hover record",
			sib._affordance_hovers["R"].is_empty())
	await wm.solo_entered

	# Interaction-lock path: hover the soloed window's handle, then lock it.
	_hover_handle(win, "R")
	_report.check("the soloed window's hovered handle shows its affordance",
			win._resize_affordances["R"].visible)
	win.set_interaction_locked(true)
	_report.check("locking hides the stranded affordance mark",
			not win._resize_affordances["R"].visible)
	_report.check("locking clears the stranded hover record",
			win._affordance_hovers["R"].is_empty())

	await _free_wm(wm)


# --- programmatic close mid-transition -------------------------------------

## Programmatically closing the soloed window during the ENTER tween resets every
## transition field, kills the tween with no stale or duplicate completion signal,
## reactivates survivors, and promotes MRU focus onto a survivor.
func _check_close_mid_enter() -> void:
	_report.section("close mid-enter")
	var wm := await _make_wm()
	await _fill_left(wm)
	var RIGHT := WindowManager.Slot.RIGHT

	var win: SWindow = wm.slots[RIGHT]
	var siblings: Array[SWindow] = []
	for other in wm.open_windows:
		if other != win:
			siblings.append(other)

	wm.solo_transition_duration = 1.0
	wm.enter_solo(win)
	_report.check("mid-enter state is ENTERING",
			wm._solo_state == WindowManager.Presentation.ENTERING)

	# Connect the emit counter BEFORE the synchronous forced exit.
	var exits := [0]
	wm.solo_exited.connect(func(): exits[0] += 1)
	win.close()

	_report.check("close resets to DOCKED",
			wm._solo_state == WindowManager.Presentation.DOCKED)
	_report.check("close clears soloed_window", wm.soloed_window == null)
	_report.check("close clears the tween", wm._solo_tween == null)
	_report.check("close emits solo_exited exactly once", exits[0] == 1, str(exits[0]))
	_report.check("the closed window left the open list", win not in wm.open_windows)
	var survivors_active := true
	for other in siblings:
		if not is_instance_valid(other) or other.is_suspended:
			survivors_active = false
	_report.check("survivors are reactivated", survivors_active)
	_report.check("focus promoted onto a surviving window",
			wm.focused_window != null and wm.focused_window in siblings)

	# No stale finished callback fires after the original full duration elapses.
	await create_timer(1.2).timeout
	_report.check("no duplicate solo_exited after the original duration",
			exits[0] == 1, str(exits[0]))

	await _free_wm(wm)


## Programmatically closing the soloed window during the EXIT tween is likewise a
## clean teardown with exactly one completion signal.
func _check_close_mid_exit() -> void:
	_report.section("close mid-exit")
	var wm := await _make_wm()
	await _fill_left(wm)
	var RIGHT := WindowManager.Slot.RIGHT

	var win: SWindow = wm.slots[RIGHT]
	var siblings: Array[SWindow] = []
	for other in wm.open_windows:
		if other != win:
			siblings.append(other)

	wm.solo_transition_duration = 0.03
	wm.enter_solo(win)
	await wm.solo_entered

	wm.solo_transition_duration = 1.0
	wm.exit_solo()
	_report.check("mid-exit state is EXITING",
			wm._solo_state == WindowManager.Presentation.EXITING)

	var exits := [0]
	wm.solo_exited.connect(func(): exits[0] += 1)
	win.close()

	_report.check("close resets to DOCKED",
			wm._solo_state == WindowManager.Presentation.DOCKED)
	_report.check("close clears soloed_window and tween",
			wm.soloed_window == null and wm._solo_tween == null)
	_report.check("close emits solo_exited exactly once", exits[0] == 1, str(exits[0]))
	_report.check("focus promoted onto a surviving window",
			wm.focused_window != null and wm.focused_window in siblings)
	_report.check("the freed window vacated its slot", wm.slots[RIGHT] == null)

	await create_timer(1.2).timeout
	_report.check("no duplicate solo_exited after the original duration",
			exits[0] == 1, str(exits[0]))

	await _free_wm(wm)


# --- contract preservation -------------------------------------------------

## A rejected window request (every slot full) must not disturb an active resize.
func _check_contract_preservation() -> void:
	_report.section("contract preservation")
	var wm := await _make_wm()
	await _fill_left(wm)
	var RIGHT := WindowManager.Slot.RIGHT

	var win: SWindow = wm.slots[RIGHT]
	var handle := Fixtures.handle(win, "R")
	_press_handle(win, "R", handle.global_position)
	_report.check("a gesture is active", win._resizing and wm.resizing_window == win)

	var overflow := wm.create_window()
	_report.check("a request with every slot full returns null", overflow == null)
	_report.check("the rejected request leaves the gesture intact",
			win._resizing and wm.resizing_window == win)

	win.cancel_resize()
	await _free_wm(wm)


# --- gesture / hover helpers -----------------------------------------------

## Emits a PRESSED handle event, starting a real resize gesture (start_resize
## projects a null pointer onto the frozen plane, so no controller is needed).
func _press_handle(win: SWindow, handle_id: String, world_pos: Vector3) -> void:
	var body := Fixtures.handle(win, handle_id)
	body.emit_signal("pointer_event",
			Fixtures.event_at(XRToolsPointerEvent.Type.PRESSED, body, world_pos))


## Drives an ENTERED onto a handle so its affordance mark shows, as a hover with
## no controller present would.
func _hover_handle(win: SWindow, handle_id: String) -> void:
	var body := Fixtures.handle(win, handle_id)
	body.emit_signal("pointer_event",
			Fixtures.event_at(XRToolsPointerEvent.Type.ENTERED, body, body.global_position))


## Whether `v` lies strictly between `a` and `b` (either order), with a small
## margin so an exactly-at-endpoint sample fails rather than passing trivially.
func _strictly_between(v: float, a: float, b: float) -> bool:
	return v > minf(a, b) + EPS and v < maxf(a, b) - EPS
