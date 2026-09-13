# Vendored addon patches

Local modifications we carry on top of third-party `addons/` code. Bumping a
vendored addon **overwrites these files**, so re-apply every patch below (or
confirm upstream has fixed it) after replacing the addon, then re-run the listed
tests.

To see the full current divergence for an addon at any time:

```sh
git log --oneline -- addons/<addon>/
git show <commit> -- addons/<addon>/<file>
```

## godot-xr-tools (`4.4.1-dev`)

Baseline caveat: the patches below are the commits made *after* the addon was
imported (`571a45f`, `1b263db`). If those import commits already diverged from a
pristine upstream `4.4.1-dev`, only a diff against a clean checkout of that
version would surface it — worth doing once when re-vendoring.

### `objects/viewport_2d_in_3d_body.gd`

- **Commit:** `b2b759c` — fix(interaction): let a hand press reclaim stale
  viewport mouse ownership.
- **What:** In `_on_pointer_event`, the press branch that assigns the `_mouse`
  pointer was `pointer is XRToolsFunctionPointer` (a hard type check). Replaced
  with the addon's own duck-typing check,
  `pointer != null and XRTools.is_xr_class(pointer, "XRToolsFunctionPointer")`.
- **Why:** Our `HandPointer` (`project/interaction/hand_pointer.gd`) is a
  `Node3D`, not an `XRToolsFunctionPointer`, so the hard check never let a hand
  press claim `_mouse`. After a solo/unsolo cycle the body could be left with a
  departed pointer as `_mouse` owner; since a `LineEdit` in a `SubViewport`
  focuses only from the synthesized mouse event (emitted solely for the `_mouse`
  pointer), later hand clicks delivered touch-only and never focused. The
  duck-typed check lets a pressing hand take `_mouse` on the spot and self-heal.
  Paired with `HandPointer.is_xr_class` returning `true` for that name.
- **Re-verify:** `tests/app_search_focus_test.gd` (the "stale pre-solo pointer
  ownership" section fails without this patch).

### `objects/keyboard/virtual_keyboard_2d.gd`

- **Commits:** `ad7bd8a` (expose keyboard input as an independent signal),
  `ecd9eca` — fix(windowing): stop typing on the virtual keyboard from moving
  the player.
- **Why:** Surface virtual-keyboard key events as a standalone signal for the
  shell/terminal, and prevent keystrokes from being consumed as player-movement
  input.
- **Re-verify:** `tests/virtual_keyboard_input_test.gd`.

### `objects/virtual_keyboard.tscn`

- **Commit:** `ad7bd8a`.
- **Why:** Scene wiring for the independent-signal change above.
- **Re-verify:** `tests/virtual_keyboard_input_test.gd`.
