extends RefCounted

## Collects one suite's results and prints them in the format every suite in
## tests/ shares:
##
##     [section name]
##       ok   some label
##       FAIL some label  (got 1.234)
##
##     PASS - all checks passed
##
## [method finish] is the only way out. It prints SUCCESS_LINE, which both
## .github/workflows/ci.yml and tests/linux/run.sh treat as the proof that a
## suite ran to completion, and quits non-zero when any check failed.

## Printed verbatim on success. The harnesses match on it, so a suite that dies
## part-way is caught even though it never reports a failure of its own.
const SUCCESS_LINE := "PASS - all checks passed"

var failures := 0


## Prints a heading for the checks that follow.
func section(title: String) -> void:
	print("[%s]" % title)


## Records one check. `detail` should carry the value actually seen; it is
## printed only when the check fails.
func check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		print("  ok   ", label)
	else:
		failures += 1
		print("  FAIL ", label, "" if detail.is_empty() else "  (got %s)" % detail)


## Records a float comparison against `want`, within `eps`.
func near(label: String, got: float, want: float, eps: float = 0.0001) -> void:
	check("%s == %.5f" % [label, want], absf(got - want) < eps, "%.5f" % got)


## Prints the summary and ends the run, exiting 0 only if every check passed.
func finish(tree: SceneTree) -> void:
	print("")
	if failures == 0:
		print(SUCCESS_LINE)
		tree.quit(0)
	else:
		print("FAIL - %d check(s) failed" % failures)
		tree.quit(1)
