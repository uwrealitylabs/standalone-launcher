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
	await _check_resize_window_gate()
	await _check_async_open()
	await _check_solo_button()
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


# --- programmatic resize gate ----------------------------------------------

## WindowManager.resize_window is the state-gated programmatic entry (SWindow.resize
## delegates through it). In DOCKED a conflicting call cancels the active gesture —
## whether it targets another window or the dragged one itself — before applying,
## so no later pointer frame resurrects the stale gesture. Mid-transition every
## resize is refused, and in SOLO only the soloed window resizes (a suspended
## sibling is rejected, its content_size untouched).
func _check_resize_window_gate() -> void:
	_report.section("resize_window gate")
	var wm := await _make_wm()
	await _fill_left(wm)
	var RIGHT := WindowManager.Slot.RIGHT
	var CENTRE := WindowManager.Slot.CENTRE

	var win_a: SWindow = wm.slots[RIGHT]
	var win_b: SWindow = wm.slots[CENTRE]

	# DOCKED: a conflicting resize on ANOTHER window cancels the active gesture,
	# then resizes the target.
	_press_handle(win_a, "R", Fixtures.handle(win_a, "R").global_position)
	_report.check("a gesture is active on win_a", win_a._resizing and wm.resizing_window == win_a)
	var expected_b := wm.clamp_content_size(win_b, Vector2(0.5, 0.5))
	wm.resize_window(win_b, Vector2(0.5, 0.5))
	_report.check("a conflicting resize cancels the active gesture first",
			not win_a._resizing and wm.resizing_window == null)
	_report.check("the conflicting resize applied to its target",
			win_b.content_size.is_equal_approx(expected_b), str(win_b.content_size))

	# DOCKED: a resize on the ACTIVELY DRAGGED window itself cancels its gesture,
	# and a following update_resize frame does not resurrect the old drag.
	_press_handle(win_a, "R", Fixtures.handle(win_a, "R").global_position)
	var expected_a := wm.clamp_content_size(win_a, Vector2(0.5, 0.5))
	wm.resize_window(win_a, Vector2(0.5, 0.5))
	_report.check("resizing the dragged window itself cancels its gesture",
			not win_a._resizing and wm.resizing_window == null)
	win_a.update_resize(Fixtures.handle(win_a, "R").global_position + Vector3(0.5, 0, 0))
	_report.check("a post-cancel update_resize does not overwrite the programmatic result",
			win_a.content_size.is_equal_approx(expected_a), str(win_a.content_size))

	# SOLO: only the soloed window resizes; a suspended sibling is rejected.
	wm.solo_transition_duration = 0.0
	wm.enter_solo(win_a)
	var sib_size := win_b.content_size
	win_b.resize(Vector2(2.0, 1.0))  # the public wrapper also routes through the gate
	_report.check("a SOLO-time resize on a suspended sibling is rejected",
			win_b.content_size.is_equal_approx(sib_size), str(win_b.content_size))
	wm.resize_window(win_a, Vector2(1.2, 0.65))
	_report.check("the soloed window resizes its solo size",
			win_a.current_solo_size.is_equal_approx(Vector2(1.2, 0.65)),
			str(win_a.current_solo_size))
	_report.check("the soloed window's content_size stays put during a solo resize",
			win_a.content_size.is_equal_approx(expected_a), str(win_a.content_size))

	# Mid-transition: every resize is refused. Pause an EXIT tween to sit in EXITING.
	wm.solo_transition_duration = 1.0
	wm.exit_solo()
	wm._solo_tween.pause()
	wm._solo_tween.custom_step(0.3)
	var held_solo := win_a.current_solo_size
	wm.resize_window(win_a, Vector2(2.5, 2.0))
	_report.check("resize_window is a no-op during EXITING",
			win_a.current_solo_size.is_equal_approx(held_solo), str(win_a.current_solo_size))
	wm._solo_tween.custom_step(1.0)  # drive home so teardown is clean
	_report.check("the exit tween still completes to DOCKED",
			wm._solo_state == WindowManager.Presentation.DOCKED)

	await _free_wm(wm)


# --- async open / ensure_docked --------------------------------------------

## request_open_window is the async public open: while DOCKED it opens immediately;
## while SOLO it animates the exit first and creates the window only once DOCKED;
## mid-transition or with every slot full it returns null without disturbing state.
## ensure_docked from SOLO never hangs on the zero-duration synchronous exit, and
## _create_window_now self-enforces the state gate.
func _check_async_open() -> void:
	_report.section("async open / ensure_docked")

	# DOCKED with a free slot: opens immediately.
	var wm := await _make_wm()  # menu CENTRE, terminal RIGHT; LEFT free
	var before := wm.open_windows.size()
	var opened: SWindow = await wm.request_open_window()
	_report.check("request_open_window while DOCKED opens a window",
			opened != null and opened in wm.open_windows
			and wm.open_windows.size() == before + 1)
	await _free_wm(wm)

	# SOLO with a free slot: animates the exit, then creates AFTER solo_exited.
	wm = await _make_wm()  # LEFT still free
	var win: SWindow = wm.slots[WindowManager.Slot.RIGHT]
	wm.solo_transition_duration = 0.03
	wm.enter_solo(win)
	await wm.solo_entered
	var count_before := wm.open_windows.size()
	var count_at_exit := [-1]
	wm.solo_exited.connect(func(): count_at_exit[0] = wm.open_windows.size())
	var w2: SWindow = await wm.request_open_window()
	_report.check("request_open_window while SOLO first exits solo",
			wm._solo_state == WindowManager.Presentation.DOCKED)
	_report.check("no window is created before the exit completes",
			count_at_exit[0] == count_before, str(count_at_exit[0]))
	_report.check("the window is created after unsoloing",
			w2 != null and w2 in wm.open_windows
			and wm.open_windows.size() == count_before + 1)
	await _free_wm(wm)

	# Mid-transition (ENTERING, then EXITING): rejected, transition undisturbed.
	wm = await _make_wm()  # LEFT free, so the preflight is not what rejects
	win = wm.slots[WindowManager.Slot.RIGHT]
	wm.solo_transition_duration = 1.0
	wm.enter_solo(win)
	wm._solo_tween.pause()
	var open_count := wm.open_windows.size()
	var during_enter: SWindow = await wm.request_open_window()
	_report.check("request_open_window during ENTERING returns null",
			during_enter == null and wm.open_windows.size() == open_count)
	_report.check("the ENTERING transition is undisturbed",
			wm._solo_state == WindowManager.Presentation.ENTERING and wm.soloed_window == win)
	wm._solo_tween.custom_step(2.0)  # completes normally
	_report.check("the interrupted-open enter still reaches SOLO",
			wm._solo_state == WindowManager.Presentation.SOLO)

	wm.exit_solo()
	wm._solo_tween.pause()
	var during_exit: SWindow = await wm.request_open_window()
	_report.check("request_open_window during EXITING returns null",
			during_exit == null and wm.open_windows.size() == open_count)
	wm._solo_tween.custom_step(2.0)
	_report.check("the interrupted-open exit still reaches DOCKED",
			wm._solo_state == WindowManager.Presentation.DOCKED)
	await _free_wm(wm)

	# SOLO with every slot full: the preflight returns null and stays in SOLO,
	# never tearing the presentation down to fail.
	wm = await _make_wm()
	await _fill_left(wm)  # all three slots occupied
	win = wm.slots[WindowManager.Slot.RIGHT]
	wm.solo_transition_duration = 0.03
	wm.enter_solo(win)
	await wm.solo_entered
	var exits := [0]
	wm.solo_exited.connect(func(): exits[0] += 1)
	var full: SWindow = await wm.request_open_window()
	_report.check("a full-workspace open while SOLO returns null", full == null)
	_report.check("the full-workspace open stays in SOLO without exiting",
			wm._solo_state == WindowManager.Presentation.SOLO
			and wm.soloed_window == win and exits[0] == 0)
	await _free_wm(wm)

	# Zero-duration ensure_docked from SOLO returns true without hanging.
	wm = await _make_wm()
	win = wm.slots[WindowManager.Slot.RIGHT]
	wm.solo_transition_duration = 0.0
	wm.enter_solo(win)
	var docked: bool = await wm.ensure_docked()
	_report.check("zero-duration ensure_docked from SOLO returns true",
			docked and wm._solo_state == WindowManager.Presentation.DOCKED)

	# _create_window_now self-enforces the state gate.
	wm.enter_solo(win)  # back to SOLO synchronously (zero duration)
	var direct := wm._create_window_now()
	_report.check("_create_window_now while not DOCKED returns null and stays SOLO",
			direct == null and wm._solo_state == WindowManager.Presentation.SOLO)
	await _free_wm(wm)


# --- solo button wiring ----------------------------------------------------

## The header's solo button reaches the manager through the full chain (button
## pressed -> header.solo_pressed -> SWindow.on_solo_requested ->
## WindowManager._on_solo_requested) and toggles solo, guarded on state: a press
## enters from DOCKED and exits from SOLO on the soloed window, while a press
## mid-transition or on a suspended sibling is ignored.
func _check_solo_button() -> void:
	_report.section("solo button wiring")
	var wm := await _make_wm()
	await _fill_left(wm)
	var win: SWindow = wm.slots[WindowManager.Slot.RIGHT]
	var header: SWindowHeader = win.header_3d.get_scene_instance()
	_report.check("the header exposes a solo button", header.solo_button != null)

	# DOCKED: a press solos this window.
	wm.solo_transition_duration = 0.0
	header.solo_button.pressed.emit()
	_report.check("a press from DOCKED enters solo",
			wm._solo_state == WindowManager.Presentation.SOLO and wm.soloed_window == win)

	# SOLO on the soloed window: a press exits.
	header.solo_button.pressed.emit()
	_report.check("a press from SOLO on the soloed window exits",
			wm._solo_state == WindowManager.Presentation.DOCKED and wm.soloed_window == null)

	# Mid-transition: a press is ignored and leaves the in-flight tween alone.
	wm.solo_transition_duration = 1.0
	header.solo_button.pressed.emit()
	_report.check("the press starts the enter transition",
			wm._solo_state == WindowManager.Presentation.ENTERING)
	wm._solo_tween.pause()
	header.solo_button.pressed.emit()
	_report.check("a press mid-transition is ignored",
			wm._solo_state == WindowManager.Presentation.ENTERING and wm.soloed_window == win)
	wm._solo_tween.custom_step(2.0)  # complete to SOLO
	_report.check("the transition still completes to SOLO",
			wm._solo_state == WindowManager.Presentation.SOLO)

	# SOLO: a press routed from a suspended sibling is ignored.
	var sib: SWindow = wm.slots[WindowManager.Slot.LEFT]
	var sib_header: SWindowHeader = sib.header_3d.get_scene_instance()
	sib_header.solo_button.pressed.emit()
	_report.check("a press on a suspended sibling is ignored",
			wm._solo_state == WindowManager.Presentation.SOLO and wm.soloed_window == win)

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
