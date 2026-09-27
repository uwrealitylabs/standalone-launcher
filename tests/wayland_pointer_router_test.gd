extends SceneTree

## Verifies WaylandPointerRouter: how several hand pointers become the one
## pointer a Wayland seat has, and which seat calls each event produces.
##
## The router is pure logic over plain data, so a recording sink stands in for
## WaylandCompositor and every check is an exact call sequence.
##
## Run with:
##   godot --headless --xr-mode off --path . \
##       --script res://tests/wayland_pointer_router_test.gd

const Report := preload("res://tests/support/report.gd")

const T := XRToolsPointerEvent.Type


## Records the WaylandCompositor input calls the router makes, as strings.
class Sink:
	extends RefCounted
	var calls: Array[String] = []

	func pointer_enter(uv: Vector2) -> void:
		calls.append("enter %s" % uv)

	func pointer_motion(uv: Vector2) -> void:
		calls.append("motion %s" % uv)

	func pointer_leave() -> void:
		calls.append("leave")

	func send_button(button: int, pressed: bool) -> void:
		calls.append("button %d %s" % [button, "down" if pressed else "up"])


var _report := Report.new()
# Stand-ins for two hands; the router only uses them as identities.
var _a := RefCounted.new()
var _b := RefCounted.new()


func _initialize() -> void:
	_check_single_hand()
	_check_grab_off_surface()
	_check_claim_from_unpressed_owner()
	_check_pressed_owner_is_kept()
	_check_owner_exit_hands_off()
	_check_overlapping_pinches()
	_check_reset_and_strays()
	_check_cancel()
	_report.finish(self)


func _router() -> Array:
	var sink := Sink.new()
	var router := WaylandPointerRouter.new()
	router.sink = sink
	return [router, sink]


func _check_single_hand() -> void:
	_report.section("one hand, full lifecycle")
	var r: Array = _router()
	var router: WaylandPointerRouter = r[0]
	var sink: Sink = r[1]
	router.handle(_a, T.ENTERED, Vector2(0.5, 0.5))
	# HandPointer follows ENTERED with a MOVED at the same point.
	router.handle(_a, T.MOVED, Vector2(0.5, 0.5))
	router.handle(_a, T.MOVED, Vector2(0.6, 0.5))
	router.handle(_a, T.PRESSED, Vector2(0.6, 0.5))
	router.handle(_a, T.MOVED, Vector2(0.7, 0.5))
	router.handle(_a, T.RELEASED, Vector2(0.7, 0.5))
	router.handle(_a, T.EXITED, Vector2(0.7, 0.5))
	var want := ["enter (0.5, 0.5)", "motion (0.6, 0.5)", "button 1 down",
			"motion (0.7, 0.5)", "button 1 up", "leave"]
	_report.check("enter, motion, button down, drag, button up, leave",
			sink.calls == want, str(sink.calls))


func _check_grab_off_surface() -> void:
	_report.section("a pressed drag keeps going past the edge")
	var r: Array = _router()
	var router: WaylandPointerRouter = r[0]
	var sink: Sink = r[1]
	router.handle(_a, T.ENTERED, Vector2(0.9, 0.5))
	router.handle(_a, T.PRESSED, Vector2(0.9, 0.5))
	router.handle(_a, T.MOVED, Vector2(1.4, 0.5))
	router.handle(_a, T.RELEASED, Vector2(1.5, 0.5))
	_report.check("motion outside 0..1 is forwarded, with no leave mid-press",
			sink.calls == ["enter (0.9, 0.5)", "button 1 down", "motion (1.4, 0.5)",
					"motion (1.5, 0.5)", "button 1 up"], str(sink.calls))
	sink.calls.clear()
	router.handle(_a, T.EXITED, Vector2(1.5, 0.5))
	_report.check("the leave comes only after release", sink.calls == ["leave"],
			str(sink.calls))


func _check_claim_from_unpressed_owner() -> void:
	_report.section("a second hand claims by pressing")
	var r: Array = _router()
	var router: WaylandPointerRouter = r[0]
	var sink: Sink = r[1]
	router.handle(_a, T.ENTERED, Vector2(0.2, 0.2))
	router.handle(_b, T.ENTERED, Vector2(0.8, 0.8))
	router.handle(_b, T.MOVED, Vector2(0.8, 0.7))
	_report.check("the first hovering hand owns the pointer",
			router.get_pointer_owner() == _a)
	_report.check("a non-owner's hover sends nothing",
			sink.calls == ["enter (0.2, 0.2)"], str(sink.calls))
	sink.calls.clear()
	router.handle(_b, T.PRESSED, Vector2(0.8, 0.7))
	_report.check("the claim moves to the new hand before its button",
			sink.calls == ["motion (0.8, 0.7)", "button 1 down"], str(sink.calls))
	_report.check("the pressing hand now owns the pointer", router.get_pointer_owner() == _b)
	sink.calls.clear()
	router.handle(_a, T.MOVED, Vector2(0.3, 0.3))
	_report.check("the old owner's motion is ignored", sink.calls.is_empty(),
			str(sink.calls))


func _check_pressed_owner_is_kept() -> void:
	_report.section("a pressed owner keeps the pointer")
	var r: Array = _router()
	var router: WaylandPointerRouter = r[0]
	var sink: Sink = r[1]
	router.handle(_a, T.ENTERED, Vector2(0.2, 0.2))
	router.handle(_a, T.PRESSED, Vector2(0.2, 0.2))
	router.handle(_b, T.ENTERED, Vector2(0.8, 0.8))
	sink.calls.clear()
	router.handle(_b, T.PRESSED, Vector2(0.8, 0.8))
	router.handle(_b, T.MOVED, Vector2(0.9, 0.8))
	router.handle(_b, T.RELEASED, Vector2(0.9, 0.8))
	_report.check("the other hand's press, drag and release send nothing",
			sink.calls.is_empty(), str(sink.calls))
	_report.check("the pressed hand still owns the pointer", router.get_pointer_owner() == _a)
	router.handle(_a, T.MOVED, Vector2(0.25, 0.2))
	router.handle(_a, T.RELEASED, Vector2(0.25, 0.2))
	_report.check("the owner's drag and release still go through",
			sink.calls == ["motion (0.25, 0.2)", "button 1 up"], str(sink.calls))


func _check_owner_exit_hands_off() -> void:
	_report.section("an unpressed owner's exit hands off")
	var r: Array = _router()
	var router: WaylandPointerRouter = r[0]
	var sink: Sink = r[1]
	router.handle(_a, T.ENTERED, Vector2(0.2, 0.2))
	router.handle(_b, T.ENTERED, Vector2(0.8, 0.8))
	router.handle(_b, T.MOVED, Vector2(0.7, 0.8))
	sink.calls.clear()
	router.handle(_a, T.EXITED, Vector2(0.2, 0.2))
	_report.check("the pointer moves to the next hand, without leaving",
			sink.calls == ["motion (0.7, 0.8)"], str(sink.calls))
	_report.check("the next hovering hand owns it", router.get_pointer_owner() == _b)
	sink.calls.clear()
	router.handle(_b, T.EXITED, Vector2(0.7, 0.8))
	_report.check("the last hand's exit leaves the surface", sink.calls == ["leave"],
			str(sink.calls))
	_report.check("nobody owns the pointer", router.get_pointer_owner() == null)

	# Defensive: an owner that exits while pressed releases before handing off.
	router.handle(_a, T.ENTERED, Vector2(0.2, 0.2))
	router.handle(_a, T.PRESSED, Vector2(0.2, 0.2))
	sink.calls.clear()
	router.handle(_a, T.EXITED, Vector2(0.2, 0.2))
	_report.check("a pressed owner's exit sends button up, then leave",
			sink.calls == ["button 1 up", "leave"], str(sink.calls))


## Both hands pinch on the surface, A first. A same-frame release is just one
## order or the other, since each HandPointer runs its own _process.
func _check_overlapping_pinches() -> void:
	_report.section("two pinches overlap: the owner releases first")
	var r: Array = _both_pinched()
	var router: WaylandPointerRouter = r[0]
	var sink: Sink = r[1]
	router.handle(_a, T.RELEASED, Vector2(0.3, 0.2))
	router.handle(_b, T.MOVED, Vector2(0.95, 0.8))
	router.handle(_b, T.RELEASED, Vector2(0.95, 0.8))
	_report.check("only the owner's press and release reach the seat",
			sink.calls == ["enter (0.2, 0.2)", "button 1 down", "motion (0.3, 0.2)",
					"button 1 up"], str(sink.calls))
	_report.check("the owner keeps the pointer, unpressed", router.get_pointer_owner() == _a)
	sink.calls.clear()
	router.handle(_a, T.EXITED, Vector2(0.3, 0.2))
	router.handle(_b, T.EXITED, Vector2(0.95, 0.8))
	_report.check("afterwards, exits hand off and then leave as usual",
			sink.calls == ["motion (0.95, 0.8)", "leave"], str(sink.calls))

	_report.section("two pinches overlap: the refused hand releases first")
	r = _both_pinched()
	router = r[0]
	sink = r[1]
	router.handle(_b, T.RELEASED, Vector2(0.9, 0.8))
	router.handle(_a, T.MOVED, Vector2(0.35, 0.2))
	router.handle(_a, T.RELEASED, Vector2(0.35, 0.2))
	_report.check("the refused release sends nothing; the owner's drag and up go through",
			sink.calls == ["enter (0.2, 0.2)", "button 1 down", "motion (0.3, 0.2)",
					"motion (0.35, 0.2)", "button 1 up"], str(sink.calls))
	_report.check("buttons balance", _buttons_balance(sink))

	_report.section("two pinches overlap: the owner releases and exits mid-pinch")
	r = _both_pinched()
	router = r[0]
	sink = r[1]
	router.handle(_a, T.RELEASED, Vector2(0.3, 0.2))
	sink.calls.clear()
	router.handle(_a, T.EXITED, Vector2(0.3, 0.2))
	_report.check("the still-pinched hand takes the pointer, unpressed",
			router.get_pointer_owner() == _b and sink.calls == ["motion (0.9, 0.8)"],
			str(sink.calls))
	# Its pinch never reached the seat, so its locked-plane drag arrives as hover,
	# clamped onto the surface, and its release must not send a stray button up.
	router.handle(_b, T.MOVED, Vector2(1.3, 0.8))
	router.handle(_b, T.MOVED, Vector2(1.4, -0.2))
	router.handle(_b, T.RELEASED, Vector2(1.4, -0.2))
	router.handle(_b, T.EXITED, Vector2(1.4, -0.2))
	_report.check("its drag is hover clamped to the edge, its release sends nothing",
			sink.calls == ["motion (0.9, 0.8)", "motion (1.0, 0.8)", "motion (1.0, 0.0)",
					"leave"], str(sink.calls))
	_report.check("buttons balance and nobody owns the pointer",
			_buttons_balance(sink) and router.get_pointer_owner() == null)
	sink.calls.clear()
	router.handle(_b, T.ENTERED, Vector2(0.5, 0.5))
	router.handle(_b, T.PRESSED, Vector2(0.5, 0.5))
	router.handle(_b, T.RELEASED, Vector2(0.5, 0.5))
	_report.check("that hand's next pinch clicks normally",
			sink.calls == ["enter (0.5, 0.5)", "button 1 down", "button 1 up"],
			str(sink.calls))

	r = _both_pinched()
	router = r[0]
	sink = r[1]
	router.handle(_b, T.MOVED, Vector2(1.3, 1.2))
	router.handle(_a, T.RELEASED, Vector2(0.3, 0.2))
	sink.calls.clear()
	router.handle(_a, T.EXITED, Vector2(0.3, 0.2))
	_report.check("a handoff to a hand already past the edge lands on the edge",
			sink.calls == ["motion (1.0, 1.0)"], str(sink.calls))

	_report.section("two pinches overlap: the owner pinches again first")
	r = _both_pinched()
	router = r[0]
	sink = r[1]
	router.handle(_a, T.RELEASED, Vector2(0.3, 0.2))
	router.handle(_a, T.PRESSED, Vector2(0.3, 0.2))
	router.handle(_b, T.RELEASED, Vector2(0.9, 0.8))
	router.handle(_a, T.RELEASED, Vector2(0.3, 0.2))
	_report.check("the owner's second click goes through; the other release is dropped",
			sink.calls == ["enter (0.2, 0.2)", "button 1 down", "motion (0.3, 0.2)",
					"button 1 up", "button 1 down", "button 1 up"], str(sink.calls))

	_report.section("two pinches overlap after a claim")
	r = _router()
	router = r[0]
	sink = r[1]
	router.handle(_a, T.ENTERED, Vector2(0.2, 0.2))
	router.handle(_b, T.ENTERED, Vector2(0.8, 0.8))
	router.handle(_b, T.PRESSED, Vector2(0.8, 0.8))
	router.handle(_a, T.PRESSED, Vector2(0.2, 0.2))
	router.handle(_b, T.RELEASED, Vector2(0.8, 0.8))
	router.handle(_a, T.RELEASED, Vector2(0.2, 0.2))
	_report.check("the claimer clicks once; the original owner's pinch is refused",
			sink.calls == ["enter (0.2, 0.2)", "motion (0.8, 0.8)", "button 1 down",
					"button 1 up"], str(sink.calls))
	sink.calls.clear()
	router.handle(_a, T.PRESSED, Vector2(0.25, 0.2))
	router.handle(_a, T.RELEASED, Vector2(0.25, 0.2))
	_report.check("the refused hand can claim back with a fresh pinch",
			sink.calls == ["motion (0.25, 0.2)", "button 1 down", "button 1 up"]
					and router.get_pointer_owner() == _a, str(sink.calls))


## A router where A owns and holds a press and B's press was refused; B has since
## dragged. Every call the setup made is left in the sink.
func _both_pinched() -> Array:
	var r: Array = _router()
	var router: WaylandPointerRouter = r[0]
	router.handle(_a, T.ENTERED, Vector2(0.2, 0.2))
	router.handle(_b, T.ENTERED, Vector2(0.8, 0.8))
	router.handle(_a, T.PRESSED, Vector2(0.2, 0.2))
	router.handle(_b, T.PRESSED, Vector2(0.8, 0.8))
	router.handle(_b, T.MOVED, Vector2(0.9, 0.8))
	router.handle(_a, T.MOVED, Vector2(0.3, 0.2))
	return r


## Whether every button down the sink saw was matched by an up.
func _buttons_balance(sink: Sink) -> bool:
	return sink.calls.count("button 1 down") == sink.calls.count("button 1 up")


func _check_reset_and_strays() -> void:
	_report.section("reset and events from unknown hands")
	var r: Array = _router()
	var router: WaylandPointerRouter = r[0]
	var sink: Sink = r[1]
	router.handle(_a, T.ENTERED, Vector2(0.2, 0.2))
	router.handle(_a, T.PRESSED, Vector2(0.2, 0.2))
	sink.calls.clear()
	router.reset()
	_report.check("reset sends nothing", sink.calls.is_empty(), str(sink.calls))
	_report.check("reset clears the owner", router.get_pointer_owner() == null)
	# The hand's gesture outlives the surface: its tail must not reach the seat.
	router.handle(_a, T.MOVED, Vector2(0.3, 0.2))
	router.handle(_a, T.RELEASED, Vector2(0.3, 0.2))
	router.handle(_a, T.EXITED, Vector2(0.3, 0.2))
	_report.check("a forgotten hand's motion, release and exit send nothing",
			sink.calls.is_empty(), str(sink.calls))
	router.handle(_a, T.ENTERED, Vector2(0.4, 0.4))
	_report.check("a fresh enter after reset enters again",
			sink.calls == ["enter (0.4, 0.4)"], str(sink.calls))

	router.sink = null
	router.handle(_b, T.ENTERED, Vector2(0.5, 0.5))
	router.handle(_b, T.PRESSED, Vector2(0.5, 0.5))
	_report.check("with no sink, events are tracked but not sent",
			sink.calls == ["enter (0.4, 0.4)"], str(sink.calls))


func _check_cancel() -> void:
	_report.section("cancel")
	var r: Array = _router()
	var router: WaylandPointerRouter = r[0]
	var sink: Sink = r[1]
	router.cancel()
	_report.check("with nothing on the surface, cancel sends nothing",
			sink.calls.is_empty(), str(sink.calls))

	router.handle(_a, T.ENTERED, Vector2(0.2, 0.2))
	router.handle(_b, T.ENTERED, Vector2(0.8, 0.8))
	sink.calls.clear()
	router.cancel()
	_report.check("a hovering pointer leaves", sink.calls == ["leave"], str(sink.calls))

	router.handle(_a, T.ENTERED, Vector2(0.2, 0.2))
	router.handle(_a, T.PRESSED, Vector2(0.2, 0.2))
	sink.calls.clear()
	router.cancel()
	_report.check("a press is released before the pointer leaves",
			sink.calls == ["button 1 up", "leave"], str(sink.calls))
	_report.check("cancel clears the owner", router.get_pointer_owner() == null)
	router.handle(_a, T.MOVED, Vector2(0.3, 0.2))
	router.handle(_a, T.RELEASED, Vector2(0.3, 0.2))
	router.handle(_b, T.MOVED, Vector2(0.7, 0.7))
	router.handle(_b, T.EXITED, Vector2(0.7, 0.7))
	_report.check("the hands' later events send nothing until they enter again",
			sink.calls == ["button 1 up", "leave"], str(sink.calls))
	router.handle(_b, T.ENTERED, Vector2(0.6, 0.6))
	_report.check("a fresh enter after cancel enters again",
			sink.calls.back() == "enter (0.6, 0.6)", str(sink.calls))
