# Implementation plan — Compositor 2: launching desktop apps into compositor windows

- **Status:** Draft
- **Predecessor:** Compositor 1 (`docs/compositor-1-input-window-plan.md`) — one interactive,
  fixed-size client in an `SWindow`.
- **Target:** Godot 4.5, OpenXR, arm64 Linux on the RB 5.
- **Branch:** `feat/compositor-2-app-launch`, from `feat/compositor-1-input` until that merges.
- **Delivery:** C2a and C2b are checkpoints on this branch, delivered in one final merge.
- **Testing constraint:** RB5 unavailable until further notice (2026-10-18). Board checks
  are deferred follow-up work and do not block this branch's development or merge.

## Context

Compositor 1 hosts one hand-picked client (`weston-terminal`) at a fixed size. The app
browser still starts apps with a bare `OS.create_process`, so they open on whatever display
the board has — or nowhere — rather than in the launcher.

Compositor 2 makes the app browser the way apps open: picking an entry launches it on its
own compositor, in an `SWindow`, and the app is usable — menus open, dialogs appear, the
window follows the size the app draws. It targets the surveyed desktop workflows within
the scope below. **GPU buffer sharing** (dmabuf, Compositor 3) remains deferred: every
frame still arrives through `wl_shm`.

### What the app survey found (Linux arm64 VM, before this plan)

Thirty-one menu apps plus Qt, SDL and Electron samples were run against the Compositor 1
bridge, one fresh compositor each:

- **GTK3** apps map today. **All GTK4 apps and foot refuse to start** — they require
  `wl_subcompositor` and `wl_data_device_manager`. With just those two globals added, 19
  of 20 GTK4 apps and foot render correctly at 2× through `wl_shm`.
- **Qt** (VLC, KCalc, FeatherPad) maps unchanged. **SDL** games map but pick their own size,
  and some only try X11 unless told `SDL_VIDEODRIVER=wayland`. **Electron** (VS Code 1.142,
  Electron 43) maps once `XDG_SESSION_TYPE=wayland` is set; otherwise it tries X11 and exits.
- The synthetic output's **logical size (960×540) is smaller than a window slot**, so GTK4
  apps shrink to fit it.
- Clients **choose their own size** (800×600, 1359×757, 1040×727 …) whatever they are
  configured with.
- **Popups are never configured**: a click on a menu sends `get_popup` + `grab`, nothing
  appears, and the app keeps running.
- **AppArmor-confined apps** (Papers) may connect only to sockets named `wayland-[0-9]*`;
  ours is `wayland-godot-<pid>`.
- **D-Bus** decides several outcomes. On a desktop's shared session bus, single-instance
  apps hand the launch to an existing copy elsewhere (ptyxis), and some block on that
  desktop's portal (SuperTux hangs; Firefox stalls 25 s). On a **private bus per app**
  (`dbus-run-session`) all 16 apps tried map; with **no bus**, all but one (yelp) do.
- Snaps (Firefox) need a systemd user session and are not worth chasing here.

Nothing above was run on the RB 5.

## Scope

**In:** the Wayland surface needed for real apps — `wl_subcompositor`,
`wl_data_device_manager`, popups, subsurfaces, extra toplevels and modal-dialog hints;
an output large enough for any slot; client-driven sizing and resize negotiation;
launching from the app browser into a
compositor window with a defined environment and per-app D-Bus; defined outcomes when an
app fails; one session per desktop entry with independently managed windows, focused on
repeat launches; pinch-drag scrolling.

**Out (later or never):** dmabuf / zero-copy GPU buffers (Compositor 3); XWayland
(X11-only apps); snaps and Flatpak; portals (file chooser, screenshare); a clipboard shared
between apps or with the launcher; drag-and-drop; IME / `text-input-v3`; client cursors;
fractional scale; `wl_touch`; desktop-entry actions ("New Window"); `Terminal=true`
entries; VR apps.

## Milestones

The work splits into two checkpoints on one branch. **C2a** gets apps started and
shown at a sensible size with basic input and normal close handling; **C2b** adds surface
trees, menus, dialogs and scrolling. Rendering in C2a is a measured outcome, not a promise
for every app that merely binds the new globals.

Priority within these milestones:

- **C2a resource-management prerequisites:** reliable lifecycle events and proven session
  process containment. Specify both in M0 and validate them before the M5 checkpoint.
- **Next:** the per-session bus in M5 and shared seat ownership before M8 presents
  multiple windows. Reuse C1's two-hand arbitration rules, extending their ownership scope.
- **M9:** explicit gesture cancellation, including tracking loss; keep it with the classifier.

### M0 — ownership and windowing contracts

Specify these interfaces before M4/M5. M0 is a small design milestone: record API/event
shapes and state transitions, then implement them in the milestones that use them.
Multi-window rendering and a general window-manager redesign are not prerequisites.

**Ownership and identity:**

| Owner | Lifetime and responsibility |
|---|---|
| `AppSession` | Owns one launch's server, socket, bus, scope and window records. |
| Window record | Identified by `WindowId`; owns presentation and parent relationship. |
| Surface record | Bridge-owned buffer and input state; destruction invalidates input targets. |

Index sessions by desktop-entry ID. A `WindowId` is session-local and never reused; it
survives unmap/remap until toplevel destruction.

The session survives individual window destruction and can temporarily have no mapped
windows. One app may connect through multiple Wayland clients. No PID, client connection
or individual toplevel alone determines the session's lifetime.

The bridge reports `window_created(id, parent_id)`, `window_mapped(id, geometry)`,
`window_committed(id, geometry, configure_serial)`, `window_unmapped(id)`,
`window_destroyed(id)` and parent changes. Frame and input APIs identify their window;
surface targets stay opaque outside the bridge. C1's `client_gone` means its tracked
toplevel was destroyed and must not be reused as session termination.

**Event reliability:** lifecycle and parent changes must arrive in order without loss.
Replace C1's fixed 16-event, drop-oldest ring with a queue that grows as needed; the main
thread drains it every frame, so it stays short. Test a burst of more than 16 mixed events
in one dispatch and assert that records, focus and slots agree with the bridge after.

**Process containment:** the session needs reliable launch diagnostics and complete
containment: every process the app starts is found and stopped at cleanup. A process group
is not enough, since shells, `setsid` and double forks leave it normally. Use systemd's
cgroup tracking: start each session in its own transient scope via `systemd-run --user
--scope --collect -p TimeoutStopSec=<grace>`, which keeps the app our child (exit status
and stderr stay available) while systemd tracks every descendant. Cleanup stops the scope:
TERM, then KILL once the grace expires (systemd's default is 90 s, so always set it). The
scope ends by itself when its last process exits, and `--collect` removes it even after a
forced stop. Orphans reparent to init, which reaps them, so add a subreaper helper only
if the chosen implementation turns out to need explicit adoption. With no systemd user
session, `systemd-run` fails with a clear message; launch fails rather than falling back
to a process group. See the [kernel's cgroup v2 documentation][cgroup-v2].

The VM (systemd 259) confirmed this on 2026-10-18: the exit status passes through;
`setsid` and double-forked jobs stay in the scope after the wrapper exits; a stop with a 2 s
grace kills TERM-ignoring jobs in about 2 s and leaves no unit; a missing binary or user
manager is reported on stderr. Docker usually lacks a user systemd, so a skipped container
run is not a pass. Whether the board starts the launcher inside a systemd user session is
a deferred board check.

**Seat ownership:** one `WaylandPointerRouter` owns arbitration for each session's seat;
window views forward events carrying their `WindowId` to that shared router. C1 already
arbitrates two hands correctly within one view. Preserve those rules while extending hover,
gesture ownership and cancellation to include window identity. A non-owning view's exit,
unmap or cancellation must not clear another view's seat focus or active gesture. Introduce
the ownership boundary with `AppSession`; exercise multiple views in M8 and pending/scroll
gestures in M9. Independent sessions still have independent seats.

`AppSession` separately reports launch failure, supervised process exit and
`session_ended(reason)` after cleanup. Use `STARTING`, `RUNNING`, `STOPPING`, `ENDED`
states. A first map enters `RUNNING`; unmapping does not destroy a window record. Initial
mapping has a configurable deadline. Once all toplevels are destroyed, allow a configurable
windowless grace period for replacement windows, then end the session and clean up remaining
processes. A new toplevel cancels that grace period. A wrapper exiting alone does neither.

**Close operations:** `request_close(window_id)` sends the compositor-to-client
`xdg_toplevel.close` event and keeps the window present and interactive until the client
unmaps or destroys it. A client may ignore the event or ask to save; normal close never
starts a forced-termination timer. `force_stop(session_id)` is a separate explicit action
that performs bounded TERM/KILL cleanup. Launcher shutdown and failed launches use session
cleanup, not a window's destructor. These close semantics follow the
[xdg-shell protocol][xdg-shell].

**Sizing:** keep `requested_size` and `committed_size` in logical surface units, buffer
dimensions in physical pixels, and `display_size` in metres. Output scale 2 changes buffer
resolution, not the requested logical size. The default display follows committed geometry
at the chosen logical-pixels-per-metre density. Oversize content is proportionally scaled
down to fit; if the frame's minimum size prevents an exact fit, letterbox inside it. Never
stretch axes independently or crop application content to meet the layout limit. Fit the
entire committed window geometry inside the actual `SWindow` content area, excluding its
header. For logical dimensions `(w, h)` and available metres `(W, H)`, use one scale
`s = min(W / w, H / h)` for a fit-to-frame presentation, giving `(s*w, s*h)` metres.
Input uses the same content rectangle and inverse scaling; letterbox margins take no app
input. Preserve the current committed aspect ratio, not the initial launch ratio: an app
may reflow and commit a new shape after a resize. Reduced text size remains a usability
tradeoff of scaling. Popup overflow is a separate limitation documented in M7.

**Focus and placement:** session ownership, slot occupancy and focus eligibility are
separate properties. A mapped, visible parented window can take focus without a slot.
Use the following policy for dialogs (separate toplevels) and menus (popup surfaces):

- **Opening a dialog:** on map, focus and keyboard routing move to the dialog. A dialog
  in a suspended group, or during a transition, takes focus once that ends.
- **Parent interaction:** block the parent's app input only while it has a dialog marked
  modal by the optional `xdg-dialog-v1` hint; a click on the blocked parent focuses that
  dialog (the most recently mapped, if several). Parenting alone is not modality: unmarked
  children leave the parent interactive, and apps without the hint filter input themselves.
- **Solo mode:** the root and attached descendants move and hide/show as one group.
  A separate dialog stays centred over its immediate parent and slightly closer to the
  user. Keep its own committed aspect and natural size, fitting it down if needed; do not
  stretch it with the parent's width/height changes. Popups share the parent's texture and
  therefore its uniform display scale; their anchors are updated when the client reflows.
  Solo controls on a child act on the group root. Unrelated groups stay suspended.
- **Closing a dialog:** if it held focus, return focus to its parent, or to normal focus
  history if the parent is gone. Its modal block clears on unmap, destruction or loss of
  the hint. A dialog closing in the background must not steal focus from another app.
- **Menus:** M7's popup grab and outside-click dismissal rules apply; menus are not separate
  dialog windows and do not consume slots.

The distinction between a parent relation and a modal hint follows
[xdg-dialog-v1][xdg-dialog]. Implement these rules in M8, with only the interfaces needed
by M5 introduced earlier.

Required traces, implemented as tests in M5/M8:

- Launch enters `STARTING`; create/map window A enters `RUNNING`; requesting close leaves
  A interactive. Refusal changes no session state. Destroying A starts the windowless grace;
  expiry enters `STOPPING`, cleanup completes, then one `session_ended` enters `ENDED`.
- While A is running, create/map child B and focus it. Destroying B restores focus to A;
  the session remains `RUNNING` with the same server, bus and scope.

### C2a — apps start and show

**M1. Missing globals** (`wl_bridge.c`). Create `wlr_subcompositor` and
`wlr_data_device_manager`. Accept `request_set_selection` so a client's own copy/paste
works within that client; nothing crosses to another app. Subsurfaces are only accepted
here — M6 draws them. Test: a C client that requires both globals initializes and maps.

**M2. Output large enough for any slot.** Advertise logical output dimensions at least as
large as the maximum requested content size, including solo mode and resizing. Keep scale
2, with the advertised mode in physical pixels twice those logical dimensions. This avoids
unnecessary toolkit clamping; it does not enforce a hard client-size limit. Test: a GTK4
app configured at the slot size maps at that size, not 960×540.

**M3. A socket name confined apps may use.** Name the socket `wayland-<n>`, picking a free
`n` starting above the usual desktop defaults, without assuming any range is reserved.
Keep lock-file checks and skip existing socket paths before binding. Test: two servers get
distinct names; a stale socket is skipped, not deleted.

**M4. Client-driven size and resize negotiation.** Implement M0's three size fields and
proportional-fit policy using committed xdg window geometry:

- Re-enable resize handles. A gesture updates `requested_size`, coalesces configures and
  shows the last committed image fitted into the current preview. A commit updates
  `committed_size`; release settles the presentation to that geometry within layout limits.
- Honour client min/max hints where they intersect layout limits. If the client's minimum
  exceeds available space, request its minimum and scale the result to fit. A client may
  refuse or round the request; do not send a configure loop trying to force compliance.
- Track configure acknowledgements and commits separately from the latest user request.
  Old replies may update the current image but cannot replace a newer requested size.
  Set and clear the interactive-resize state at gesture boundaries.
- Apply client commits through a presentation update path that does not call the current
  `WindowManager.resize_window()`: it cancels active gestures and rejects transition-time
  updates. Preserve gesture ownership and the opposite-edge anchor across client replies.
- During solo transitions, retain new committed geometry and fit it into the animated
  frame; settle at transition end. Preserve the docked requested size for the return path.
  Move attached dialogs with the root, recompute their centred positions and uniform fit,
  and avoid inheriting a non-uniform scale from the parent's changing frame.

This replaces C1's fixed-size policy (`SWindow.has_fixed_size`). Tests cover refused and
rounded sizes, oversized and very small windows, logical versus buffer size at 2×, pointer
mapping through letterboxing, delayed replies during a gesture, and commits during both
solo transitions. Scaling down does not reduce the source buffer's copy cost.
Assert equal horizontal/vertical display scales and all four content corners inside the
usable frame throughout resizing and solo transitions; margins must not generate app clicks.

**M5. Launch from the app browser** (`app_registry.gd`, `window_manager.gd`, new
`AppSession`). Preserve the source path and desktop-entry ID during discovery; display
names are labels and must not merge distinct entries. Check for an existing session before
checking slot availability. A new launch reserves a slot and starts a session with its own
server and socket. Build argv and the environment in one place, without shell interpolation:

| Variable | Value | Why |
|---|---|---|
| `WAYLAND_DISPLAY`, `XDG_RUNTIME_DIR` | the app's server | where to connect |
| `DISPLAY` | unset | no silent fallback to an X server |
| `XDG_SESSION_TYPE` | `wayland` | Electron 43 picks its backend from it |
| `GDK_BACKEND`, `QT_QPA_PLATFORM`, `SDL_VIDEODRIVER` | `wayland` | some builds default to X11 |
| `DBUS_SESSION_BUS_ADDRESS` | session-owned bus | isolate service activation from the host |

Start the session's private bus as its own scope, `dbus-daemon --session --nofork
--address=unix:path=<session dir>/bus`, then the app in M0's app scope with that address.
Do not use [`dbus-run-session`][dbus-run-session]: it ends the bus when its direct child
exits; the VM confirmed that a forked-off descendant then loses the bus while running.
A separate bus scope lives as long as the session and keeps bus processes out of the app
scope's liveness. The session stays alive while its app scope has processes or windows,
not while the first process does: wrappers that exit after forking are normal. Report
exec failures and process exits separately. Cleanup stops the app scope, then the bus
scope, before stopping the server.

Validate wrapper exit before mapping, double forks, `setsid`, and terminal jobs ignoring
HUP/TERM, plus retry after cleanup. Work handed to unrelated host services, outside the
scope, is unsupported and must be recorded.

`dbus-daemon` is required, like the user systemd: without it, launch fails with a clear
message. Remove inherited `DBUS_STARTER_*` variables and always set the session address, so
apps never fall back to the host bus. Test that a GTK and a Qt app with a host
single-instance copy already running connect only to the session bus and open locally.

A private bus is not a universal single-instance guarantee: application locks
outside D-Bus may still redirect launches. An exit code alone cannot identify the failing
stage, since `systemd-run` and apps share codes like 1; preserve the stage and stderr.

Defined launch and lifecycle outcomes:

| What happens | Outcome |
|---|---|
| no free slot | launch refused with a message; nothing starts |
| executable cannot be started | cleanup; "could not start" with executable and diagnostic |
| server, bus or scope fails | cleanup; "could not start" with failing stage |
| supervised app work exits before mapping | cleanup; "exited" with the available code |
| no surface before the initial-map deadline | stop the session; "did not open a window" |
| wrapper exits; descendants/windows remain | keep supervising and any initial-map deadline |
| one toplevel is destroyed after mapping | remove that window only; retain surviving windows |
| last toplevel is destroyed | start the windowless grace; cleanup if no replacement appears |

Implement `request_close` and `force_stop` as separate operations. The header close button
uses `request_close`, leaving the window and slot available for save/cancel interaction.
During C2a, retain records for additional toplevels but do not present them; report that
additional windows need C2b. Never treat an unseen save dialog as permission to terminate.
Close flows requiring those dialogs are an explicit C2a compatibility limitation.

**Repeat launches focus, not duplicate.** As on a desktop dock, picking an entry whose app
already has a session focuses its most recently focused eligible window; nothing new
starts. Restore that window's presentation group if necessary. A pick while starting or
temporarily windowless reports that state; a pick while stopping waits for cleanup before
a new launch is allowed. The session registry lives outside the app-browser UI so closing
the browser cannot lose ownership. Deduplication covers launcher picks of the same entry,
not every external launch or multiple entries pointing to the same executable.

Tests include equal display names with different IDs, repeat picks with no free slot,
startup failure and retry, close refusal without signals, wrapper exit before mapping,
and timeout cleanup of the bus and app descendants. Include the containment and bus
fixtures above. Check actual process and socket cleanup in the VM; fake-process tests alone
are insufficient.

The menu and terminal take two of the three slots today, so one app fits at a time. That
is acceptable for C2; freeing slots is windowing work.

### C2b — apps are usable

**M6. Surface trees: subsurfaces and popups in one image.** Composite each toplevel's
surface tree into its texture in wlroots stacking order. Retain buffers or copied pixels
per surface, rather than C1's one pending root buffer. Redraw when any applied surface
state changes, including child-only commits, position, stacking, unmap and destruction.
Respect synchronized subsurface state: cached changes become visible only when applied by
the parent commit. Desynchronized children can update independently. Send frame callbacks
for participating surfaces, including when the root has not committed. These distinctions
follow the [core Wayland surface/subsurface protocol][wayland-core].

Handle premultiplied alpha, per-surface scale and buffer transforms, and release held
buffers on replacement and destruction. Derive window bounds from the surface tree and
xdg geometry rather than C1's root-buffer intersection. Clip drawing and pointer hit tests
to the same presented content rectangle. Use `wlr_xdg_surface_surface_at` for tree hit
testing and transform input into the selected surface's coordinates.

Tests: known overlapping pixels and input regions; a desynchronized child animating while
the root stays unchanged; synchronized updates withheld until a parent commit; mixed
scales and translucent overlaps; child movement/removal clearing old pixels; destruction
with pending buffers. Exercise popup pixels with a minimal configure fixture here; M7
adds their production configure/grab lifecycle.

**M7. Popup configure and grabs.** Configure popups after their initial commit using the
positioner and the toplevel's window geometry as the constraint box. Apply only permitted
flip/slide/resize adjustments; fitting inside the window is not guaranteed. Clip remaining
overflow consistently for drawing and input, and record inaccessible menu items as a
compatibility caveat. Handle reposition requests and recalculate nested popup coordinates.
These policies build on the [xdg-shell positioner and popup contracts][xdg-shell].

This is the explicit exception to M4's full-window fit policy. Preserving a toplevel's
aspect ratio cannot make a menu outside its geometry visible. Do not shrink the whole app
each time a menu opens: that would move controls under the pointer. Fully visible overflow
menus need additional presentation space and remain deferred; an affected workflow must
be recorded as impaired, not reported as working without caveats.

Validate grabs through wlroots, give the topmost grabbing popup keyboard focus, and dismiss
the chain with `popup_done` on an outside click. Route outside clicks from launcher headers
and other windows through the dismissal path too; consume that click so it cannot also
activate underlying controls. Restore focus after dismissal and cancel grabs when their
owner disappears. Tests include GTK4 key navigation, nested submenus, repositioning,
disallowed adjustments, oversized menus, clicks outside the XR panel and parent destruction.

**M8. Extra toplevels** (dialogs, About boxes, file pickers drawn by the app). C1 closes
any second toplevel. Present the session's tracked toplevels, each in its own `SWindow`:

- a toplevel with a parent (`xdg_toplevel.set_parent`) opens centred on its parent, a
  small step closer to the user, without taking a slot. It follows the parent's movement,
  remains focusable and follows M0's group visibility and focus-restoration rules;
- a parentless toplevel takes a free slot. If none is free, report the refusal and send
  `close`, retaining its record until destruction. Close is advisory: keep responding to
  the initial configure lifecycle even if the client ignores it; do not kill the session;
- track parent changes. When a parent is destroyed, follow the protocol's parent update;
  a surviving child with no parent needs a slot and otherwise follows the refusal policy.
  Do not cascade process termination from a parent window's destruction;
- add `xdg_wm_dialog_v1` using the pinned wlroots version's dialog support, verifying the
  API in that version. Track modal hint changes and apply M0's blocking rule to the
  parent only, leaving independent windows usable;
- a dialog in a solo group takes input without exiting solo mode; unrelated groups remain
  suspended. Apply M0's centred placement and aspect-preserving fit throughout the tween.
  Queue focus changes during transition locks, then apply them at completion.

Tests: About and save-confirmation dialogs, cancelling close, closing a child while the
parent becomes usable again, two independent windows with one closed, dialogs during solo
and transitions, reparenting, parent destruction, and refusal with an uncooperative client.
Test a modal hint and its removal, a modeless child with an interactive parent, and
background closes that do not steal focus. Test two hands on different toplevels sharing one
seat: ownership handoff, a second press during a drag, and closing a non-owning view without
clearing the owner's pointer state. Check that both popup and dialog hit coordinates match
their presentation after entering and exiting solo mode.

**M9. Pinch-drag scrolling.** Pinch and drag to scroll, with content following the hand.
Our pinch-drag is already Wayland's click-drag (text selection, sliders), so the pinch has
to be classified before the client sees a button:

| Pinch | Becomes |
|---|---|
| released before moving past the slop | a click (button down and up at release) |
| moves past the slop before the hold time | finger-source scroll, stopped on release |
| held still past the hold time, then moved | a button drag, as in C1 (select, drag a slider) |
| cancelled before release | end the gesture without generating a pending click |

- **Slop:** a few millimetres of hand travel. **Hold time:** about 300 ms. Exercise both in
  the simulator now; tuning with real hand-tracking jitter is deferred until RB5 is available.
- Lock both the window and the surface under the initial pinch for a scroll sequence.
  Suppress pointer retargeting while scrolling; compute deltas on the locked window's live
  plane, converted through its display scaling into logical surface units. Sign deltas so
  content moves with the hand. Resume hover hit testing when the sequence ends.
- Source `finger` and `axis_stop` enable client-side kinetic scrolling; momentum remains
  toolkit-dependent and must be measured, not promised. Follow [axis event grouping and
  termination rules][wayland-core]. Stop each active axis on release or cancellation while
  its target is live; destruction invalidates the lock without sending to a dead resource.
- Add `CANCELLED` as an explicit gesture event alongside PRESSED / MOVED / RELEASED,
  routed to one idempotent cancellation handler. It is an interruption, not another input
  mode. Pending gestures produce no button events; active scrolls send axis stops; active
  button drags release an already-sent button while its target is live. Cancellation cannot
  undo input already delivered to an app. A dead target is only forgotten.
- Cancel on focus loss, suspension, target destruction or tracking loss. A common tracking
  case is a pinching hand becoming occluded or leaving the cameras' tracking volume.
  Check tracking validity before processing pinch release; a trigger reading of zero alone
  cannot distinguish tracking loss from intentional release. After tracking returns, require
  an unpinched observation before accepting a new pinch. Moving off the collider while
  tracking remains valid continues the locked drag and is not cancellation.
- Existing prerequisite, not new to M9: the target runtime must provide the pinch/`trigger`
  input `HandPointer` already reads. C1's click and drag have so far been tested only in the
  simulator, so this remains an integration risk shared with C1. The active action map has
  no `hand_interaction_ext` profile, but that alone does not prove input is broken; verify
  on the RB5 when available.
- New M9 requirement: tracking loss cancels an in-progress gesture instead of being read
  as a normal release.
- Use a project-owned cancellation signal/event adapter; the existing XR Tools enum has
  no CANCELLED member. Route target destruction directly through the shared router rather
  than sending to a freed node. Cover a second hand attempting ownership during a pending
  gesture and cancellation of a different window on the same seat.
- The cost: a click's button-down waits for release, and a drag needs a short hold first.
- Applies to compositor windows only; `SubViewport` windows keep their current behaviour.
- The classifier lives in the seat's shared `WaylandPointerRouter`. Extend `HandPointer`
  with tracking-loss detection and cancellation delivery; adapt it at the compositor input
  boundary so existing SubViewport consumers retain their event contract. The XR simulator
  drives ordinary pinches as today (hold Q or E, hold the left mouse button, move the mouse)
  and gains a deterministic tracking-loss fixture.

`wl_touch` would require an additional touch input path and toolkit compatibility work;
C2 keeps the existing pointer/hover path. Tests: the classifier's three outcomes from
scripted pinch streams; finger-source axes and stops without button events for a fast
drag; crossing a subsurface boundary without redirecting scroll; cancellation and target
destruction; motionless holds; and pointer coordinates after a window scales or resizes.
Exercise tracking loss through the actual HandPointer-to-router path during pending,
scroll and button-drag gestures, including recovery while the hand is still pinched.

## Key files

- `native/bridge/wl_bridge.{c,h}` — globals, output mode, socket naming, surface-tree
  compositing, popups, toplevel list. Still the only place wlroots types exist.
- `native/src/wayland_compositor.{cpp,h}` — per-toplevel textures and signals; size-change
  and new-toplevel signals.
- `project/compositor/compositor_poc.gd` — move process/server ownership into `AppSession`;
  keep window presentation and input here or in its replacement view.
- `project/compositor/wayland_pointer_router.gd` — shared seat ownership and gesture routing.
- `project/interaction/hand_pointer.gd` — M9 tracking-loss detection and cancellation delivery.
- `project/windowing/{swindow.gd,window_manager.gd}` — client-driven size, re-enabled
  resize, parented-window groups and normal close routing.
- `project/launch_service/app_registry.gd`, new session and launch-spec modules — identity,
  environment, the scope-and-bus launch command, launch outcomes and repeat-launch focus.
- `project/utils/file_utils.gd` — preserve desktop-entry identity during discovery.
- `native/tests/`, `tests/` — protocol, GDScript and real-process tests.

The threading contract is unchanged: all bridge calls on Godot's main thread.

## Commit sequence

M0 contracts → C2a: M1 → M2 → M3 → M4 → M5 → C2a Linux/VM checkpoint.
Prove lifecycle-event delivery and process containment early, before building M5 ownership
on them. The per-session bus is also required at this checkpoint; multi-view seat
arbitration is validated in M8, and tracking-loss cancellation remains M9 work.
Keep changes reviewable; supervision, resize negotiation and launch UI may need separate
commits within their milestone. Keep C2a on `feat/compositor-2-app-launch` and continue
directly into C2b after its checkpoint; no separate branch or C2a merge is required.

C2b: M6 → M7 → M8 → M9 → combined regression checks → one final C2 merge.
The M9 classifier can be developed earlier against a fake sink, but surface locking needs
M6 and must be tested with M7 grabs and M8 focus changes. Use VM measurements at M5/M6/M8 for
regression comparisons. RB5 validation remains a separately tracked follow-up.

## Tests

- **C, against real wlroots 0.20.2** (Linux arm64): globals, output dimensions, sockets,
  per-window event IDs and lifetime, lifecycle bursts beyond the old queue capacity,
  configure/commit negotiation, close refusal, dynamic
  surface trees, popup lifecycle, parenting/refusal, and finger-source axes with stops.
- **GDScript, headless** (Mac-runnable where no extension is needed): launch-spec and
  identity handling; session transitions using fake processes; repeat launch; sizing during
  gestures/solo transitions; dialog focus and suspension; shared-seat ownership across views;
  classifier and actual input-path cancellation, including tracking loss and recovery.
- **Linux integration:** actual exec failures, bus startup failure, wrapper exit before
  child mapping, timeout and forced scope cleanup (double forks, `setsid`, HUP/TERM-resistant
  jobs), missing user systemd or `dbus-daemon`, windowless grace, and retry without leaked
  processes, sockets or slot reservations. Run in the VM, which has a user systemd; include
  real `.desktop` fixtures and quoting cases.
- **Manual, Linux arm64 VM:** the stage-specific app scenarios below from the app browser.
- **Manual, Linux arm64 VM at M5/M6/M8:** record frame-time distribution, copy/composite/
  upload time, CPU/memory usage and buffer sizes for regression comparisons in that VM.
- **Deferred, RB5 when available:** run available representatives and record D-Bus/AppArmor
  behaviour plus frame-time distribution, upload/copy/composite time, CPU and memory usage,
  logical/buffer dimensions and software-renderer settings. Compare against C1 at matched
  sizes and include multiple surfaces/windows. Record regressions and the supported
  workload before claiming board performance. These checks do not gate the current merge.

Every headless run uses `--xr-mode off`.

## Acceptance criteria

Use `weston-terminal`, foot, one GTK3 app, two GTK4 apps (one with a menu bar, one with a
dialog), one Qt app, one SDL game and VS Code as the representative set. Record exact app
and toolkit versions, launch arguments and renderer settings. Assign applicable scenarios
per app: a game does not need to have a menu bar or an editable document.

### C2a — development checkpoint

- On the VM, representatives launch from the browser, map their primary window, display
  with correct aspect and input coordinates, take basic pointer/keyboard input, and follow
  M4 sizing policy, including clients that refuse a requested size.
- Header close sends a normal close event. A protocol fixture that refuses close remains
  interactive with no TERM/KILL; a cooperative app closes and the session cleans up.
  Extra surfaces, menus, dialogs and scrolling are not C2a requirements. Record apps whose
  launch or close workflow needs them as C2b blockers rather than claiming those flows work.
- Every M5 failure path, repeat launch and cleanup test passes, including actual Linux
  process containment and checks that apps reach only their session bus. Lifecycle bursts
  lose no ownership events. No supported launch leaks children, sockets, windows or
  reservations.
- Record VM measurements and outstanding board checks. RB5 is unavailable until further
  notice; this checkpoint proceeds using the available Linux and VM evidence.

### C2b — interactive desktop workflows

- Retain C2a behaviour and pass dynamic surface-tree, popup, multi-window and scroll tests.
- On the VM, applicable representatives open menus/submenus, accept menu keyboard input,
  scroll long views, open dialogs, and complete save/cancel close flows. Closing a child
  or one independent window leaves the rest of the session usable.
- Dialogs take focus on opening and return it on closing; marked modal dialogs block their
  parent, while modeless children leave it interactive. Both remain correctly placed and
  undistorted in docked and solo modes. Popup and scroll targets release cleanly on
  cancellation or destruction. Record kinetic scrolling separately from basic correctness.
- Complete combined C2a/C2b regression checks on Linux/VM before the branch's single merge.
  Report popup clipping and unsupported-app cases explicitly. Board workflows, hand-tracking
  tuning and performance measurements remain deferred until the RB5 becomes available.
- Maintain a compatibility table for every surveyed app with separate C2a/C2b results:
  works / works with caveat / fails, scenario, environment and reason. Unrun board cases
  remain unverified. Do not claim OpenXR, hand tracking or rendering performance from
  headless or VM-only tests.

## Risks

| Risk | Response |
|---|---|
| GL clients fail on the board's shm-only path | Unverified until RB5 returns; record VM setup. |
| No `dbus-daemon`, or apps need host services | Launch fails clearly; record affected apps. |
| Missing board packages or different confinement | Check when RB5 returns; record gaps. |
| Large buffers or many surfaces cost too much CPU | Scaling saves no copying; measure early. |
| Popup clipping hides menu items | Record as a usability caveat; overflow panels are deferred. |
| One slot free for apps | Accept for C2; slot count is windowing's call. |
| Pinches misclassified by hand-tracking jitter | Simulator tests now; board tuning deferred. |
| No user systemd where the board starts the launcher | Prove in the VM; check on the board. |
| Pinch unproven on hand-only hardware | Shared with C1 (simulator only); verify on RB5. |

Software-renderer experiments include `GSK_RENDERER=cairo` or `LIBGL_ALWAYS_SOFTWARE=1`
where supported by the installed toolkit. Record these per app; the VM's llvmpipe results
are not evidence of an automatic fallback on the board.

[xdg-shell]:
  https://github.com/wayland-mirror/wayland-protocols/blob/main/stable/xdg-shell/xdg-shell.xml
[xdg-dialog]:
  https://wayland.app/protocols/xdg-dialog-v1
[wayland-core]: https://wayland.freedesktop.org/docs/html/apa.html
[dbus-run-session]: https://dbus.freedesktop.org/doc/dbus-run-session.1.html
[cgroup-v2]: https://docs.kernel.org/admin-guide/cgroup-v2.html
