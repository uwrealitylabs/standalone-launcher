# Vendored addon patches

Local modifications we carry on top of third-party `addons/` code. Bumping a
vendored addon **overwrites these files**, so re-apply every patch below (or
confirm upstream has fixed it) after replacing the addon, then re-run the listed
tests.

## godot-xr-tools

**Upstream baseline: `571a45f` = Godot XR Tools 4.5.0 (upstream `90495f1`).**
That import commit matches the official 4.5.0 release for all 470 authored
source, scene, resource, doc, and binary-asset files (release ZIP verified
against GitHub's published SHA-256). The only non-authored difference is
locally regenerated Godot import metadata in 42 of 46 `.import` files — expected
churn, not a patch.

Do **not** use a later commit (e.g. `1b263db`) as the baseline: several already
carry local edits. Ignore `plugin.cfg` for versioning — it reads `4.4.1-dev`,
but that string ships inside the official 4.5.0 package and there is no upstream
`4.4.1` tag; this is 4.5.0.

Authoritative current divergence at any time (authored files only):

```sh
git diff 571a45f -- addons/godot-xr-tools/ ':(exclude)addons/godot-xr-tools/**/*.import'
```

### `xr_tools.gd` — tracker type in the two hand-offset helpers

Baseline declares `var xr_tracker : XRControllerTracker` at both
`XRServer.get_tracker` profile-lookup sites. Both were changed locally, and
**inconsistently**:

- `get_palm_offset` (~L333): `XRControllerTracker` → `XRPositionalTracker`
  (`1b263db`).
- `get_aim_offset` (~L392): `XRControllerTracker` → untyped `var xr_tracker`
  (`6bf753d`).

Reconcile these to one form when re-vendoring. No dedicated test.

### `hands/animations/left/hand_blend_tree.tres`, `.../right/hand_blend_tree.tres`

- **Commit:** `1a07c5f` (blend-tree `node_connections` reordered — the
  `output` edge moved to the front of the array; later re-touched via merge
  history in `6bf753d`).
- **What:** serialization reordering of `node_connections`; appears
  semantically equivalent but is a real file diff from upstream.
- No dedicated test.

### `objects/keyboard/virtual_keyboard_2d.gd`

- **Commits:** `ad7bd8a` (add `signal key_pressed(event: InputEventKey)`),
  `ecd9eca` — fix(windowing): stop typing from moving the player.
- **What:** emit key events via the new `key_pressed` signal instead of
  `Input.parse_input_event(input)`. A virtual key has no matching release, so
  injecting into the `Input` singleton latches it as held forever; the shell/
  terminal consume the signal directly instead.
- **Re-verify:** `tests/virtual_keyboard_input_test.gd`.

### `objects/virtual_keyboard.tscn`

- **Commit:** `ad7bd8a`.
- **What:** scene wiring for the `key_pressed` change above. Sub-resource IDs
  also differ, but those are editor-regenerated, not authored.
- **Re-verify:** `tests/virtual_keyboard_input_test.gd`.

### `objects/viewport_2d_in_3d_body.gd`

- **Commit:** `b2b759c` — fix(interaction): let a hand press reclaim stale
  viewport mouse ownership.
- **What:** the press branch that assigns the `_mouse` pointer used a hard
  `pointer is XRToolsFunctionPointer` check. Replaced with the addon's own
  duck-typing check,
  `pointer != null and XRTools.is_xr_class(pointer, "XRToolsFunctionPointer")`.
- **Why:** our `HandPointer` (`project/interaction/hand_pointer.gd`) is a
  `Node3D`, not an `XRToolsFunctionPointer`, so the hard check never let a hand
  press claim `_mouse`. After a solo/unsolo cycle the body could be left with a
  departed pointer as `_mouse` owner; a `LineEdit` in a `SubViewport` focuses
  only from the synthesized mouse event (emitted solely for the `_mouse`
  pointer), so later hand clicks delivered touch-only and never focused. The
  duck-typed check lets a pressing hand take `_mouse` and self-heal. Paired with
  `HandPointer.is_xr_class` returning `true` for that name.
- **Re-verify:** `tests/app_search_focus_test.gd` (the "stale pre-solo pointer
  ownership" section fails without this patch).
