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
	_check_reset_and_strays()
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
