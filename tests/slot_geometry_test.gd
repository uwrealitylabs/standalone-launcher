extends SceneTree

## Unit-covers the pure Phase 0 slot geometry, width derivations, the
## permutation-safe width cap, and tunable validation on WindowManager. None of
## this drives live window placement yet, so the manager is exercised as a bare
## object without its scene, startup windows, or keyboard.
##
## Run with:
##   godot --headless --xr-mode off --path . \
##       --script res://tests/slot_geometry_test.gd
##
## --xr-mode off is required: without it a modal OpenXR alert hangs the run.

const Report := preload("res://tests/support/report.gd")

const EPS := 0.0001

var _report := Report.new()


## A fresh manager carrying the script's default Layout tunables, with no scene
## children so nothing runs _ready or creates windows.
func _manager() -> WindowManager:
	return WindowManager.new()


## A bare window whose only meaningful state is its content width.
func _win(width: float) -> SWindow:
	var w := SWindow.new()
	w.content_size = Vector2(width, 0.75)
	return w


func _initialize() -> void:
	var wm := _manager()
	var C := wm.reference_point
	var R := wm.radius
	var theta := wm.slot_angle

	# --- slot centres sit on the arc ---
	_report.section("slot centres on the arc")
	for slot in [WindowManager.Slot.LEFT, WindowManager.Slot.CENTRE, WindowManager.Slot.RIGHT]:
		var xf: Transform3D = wm.slot_transform(slot)
		_report.near("slot %d centre is R from C" % slot, xf.origin.distance_to(C), R, EPS)
	# Arc centre sits at the player head pose, so CENTRE lands straight ahead at
	# z = -radius (radius 3 -> z = -3).
	_report.check("CENTRE lands straight ahead at z = -radius",
			wm.slot_transform(WindowManager.Slot.CENTRE).origin.is_equal_approx(
					Vector3(0.0, 1.5, -R)),
			str(wm.slot_transform(WindowManager.Slot.CENTRE).origin))
	_report.check("RIGHT centre has positive local X",
			wm.slot_transform(WindowManager.Slot.RIGHT).origin.x > EPS,
			str(wm.slot_transform(WindowManager.Slot.RIGHT).origin.x))
	_report.check("LEFT centre has negative local X",
			wm.slot_transform(WindowManager.Slot.LEFT).origin.x < -EPS,
			str(wm.slot_transform(WindowManager.Slot.LEFT).origin.x))

	# --- slot orientation faces the reference point ---
	_report.section("slot orientation")
	for slot in [WindowManager.Slot.LEFT, WindowManager.Slot.CENTRE, WindowManager.Slot.RIGHT]:
		var xf: Transform3D = wm.slot_transform(slot)
		var phi: float = wm.slot_phi(slot)
		_report.check("slot %d face normal points to C" % slot,
				xf.basis.z.dot(C - xf.origin) > EPS,
				"%.4f" % xf.basis.z.dot(C - xf.origin))
		_report.check("slot %d local X is tangent to the circle" % slot,
				xf.basis.x.is_equal_approx(Vector3(cos(phi), 0.0, sin(phi))),
				str(xf.basis.x))
		_report.check("slot %d basis is orthonormal" % slot,
				xf.basis.orthonormalized().is_equal_approx(xf.basis)
						and xf.basis.determinant() > 0.0,
				"det %.4f" % xf.basis.determinant())

	# --- width derivations round-trip ---
	_report.section("width derivations")
	_report.near("default_width == 2R tan(beta_default)", wm.default_width(),
			2.0 * R * tan(wm.default_half_width), EPS)
	_report.near("width_of_beta inverts beta_of_width", wm.width_of_beta(wm.beta_of_width(1.3)),
			1.3, EPS)
	_report.near("beta_of_width inverts width_of_beta",
			wm.beta_of_width(wm.width_of_beta(0.4)), 0.4, EPS)

	# --- permutation-safe width cap ---
	_report.section("permutation-safe cap")
	var win := _win(wm.default_width())

	# With no other open window, the cap is set against a default-width neighbour.
	wm.open_windows = [win]
	var cap_alone := wm.max_content_width_for(win)
	_report.near("cap alone == theta - g - beta_default", cap_alone,
			wm.width_of_beta(theta - wm.gutter_angle - wm.default_half_width), EPS)

	# A wider open window (here standing in for a stashed one -- it occupies no
	# slot yet still must stay safe beside every neighbour) tightens the cap.
	var wide := _win(2.5)
	wm.open_windows = [win, wide]
	var beta_wide := wm.beta_of_width(2.5)
	var cap_beside_wide := wm.max_content_width_for(win)
	_report.near("cap beside a wide window == theta - g - beta_wide", cap_beside_wide,
			wm.width_of_beta(theta - wm.gutter_angle - beta_wide), EPS)
	_report.check("a wider open neighbour narrows the cap", cap_beside_wide < cap_alone - EPS,
			"%.4f vs %.4f" % [cap_beside_wide, cap_alone])

	# The two-widest invariant beta_1 + beta_2 + g <= theta holds when win takes
	# exactly its cap beside the widest other window.
	_report.check("cap keeps the two-widest sum within theta",
			wm.beta_of_width(cap_beside_wide) + beta_wide + wm.gutter_angle <= theta + EPS,
			"%.4f" % (wm.beta_of_width(cap_beside_wide) + beta_wide + wm.gutter_angle))

	# The numeric maximum wins when the angular bound is looser: a tiny angle and
	# a large radius let the angular cap exceed the numeric limit.
	wm.open_windows = [win]
	wm.radius = 100.0
	_report.near("numeric limit caps a very loose angular bound",
			wm.max_content_width_for(win), SWindow.MAX_CONTENT_SIZE.x, EPS)
	win.free()
	wide.free()
	wm.free()

	# --- tunable validation ---
	_report.section("tunable validation: hard preconditions clamp")
	var bad := _manager()
	bad.radius = -1.0
	bad.slot_angle = PI
	bad.gutter_angle = -0.5
	bad.min_height = 3.0
	bad.max_height = 3.0
	bad.validate_tunables()
	_report.check("radius clamped positive", bad.radius > 0.0, str(bad.radius))
	_report.check("slot_angle clamped below PI/2", bad.slot_angle < PI / 2.0, str(bad.slot_angle))
	_report.check("gutter_angle clamped non-negative", bad.gutter_angle >= 0.0,
			str(bad.gutter_angle))
	_report.check("heights clamped to numeric limits with min <= max",
			bad.min_height <= bad.max_height
			and bad.min_height >= SWindow.MIN_CONTENT_SIZE.y
			and bad.max_height <= SWindow.MAX_CONTENT_SIZE.y,
			"%.3f/%.3f" % [bad.min_height, bad.max_height])
	bad.free()

	# --- default size stays 16:9 ---
	_report.section("default size holds 16:9 through clamping")
	var ar := _manager()
	ar.validate_tunables()
	var ds := ar.default_size()
	_report.near("default_size is 16:9", ds.x / ds.y, SWindow.CONTENT_ASPECT, EPS)
	# Force a width that overflows the numeric cap; the ratio must survive the clamp.
	ar.radius = 100.0
	ar.default_half_width = deg_to_rad(30.0)
	var big := ar.default_size()
	_report.near("16:9 preserved after clamping", big.x / big.y, SWindow.CONTENT_ASPECT, EPS)
	_report.check("clamped default within numeric limits",
			big.x <= SWindow.MAX_CONTENT_SIZE.x + EPS
			and big.y <= SWindow.MAX_CONTENT_SIZE.y + EPS,
			"%.3f x %.3f" % [big.x, big.y])
	ar.free()

	_report.section("tunable validation: fit constraint only warns")
	var loose := _manager()
	# 2 * 25deg + 5deg = 55deg > 45deg: adjacent defaults would overlap.
	loose.default_half_width = deg_to_rad(25.0)
	var before := loose.default_half_width
	loose.validate_tunables()
	_report.near("a fit violation leaves the tunable unchanged", loose.default_half_width,
			before, EPS)
	_report.check("geometry still computes after a fit warning",
			is_finite(loose.default_width()), str(loose.default_width()))
	loose.free()

	_report.finish(self)
