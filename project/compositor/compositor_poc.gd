extends Node3D

## Card 1 proof: shows one Wayland client on a fixed quad.
##
## Owns the client process outright — creation, liveness, and teardown — while
## [WaylandCompositor] owns polling and the texture. Splitting process ownership
## across the GDScript/C++ boundary is how children get double-reaped or leaked.
##
## Deliberately not an [SWindow]: that class drives an [XRToolsViewport2DIn3D]
## and a [SubViewport], neither of which a compositor-owned texture fits.

const CLIENT_COMMAND := "weston-simple-shm"

## Exit code a shell reports for "command not found". [method OS.create_process]
## cannot report a failed exec, so a missing client still yields a live pid and
## this code is the only evidence it never started.
const EXIT_NOT_FOUND := 127

## How long to let the client exit on SIGTERM before escalating to SIGKILL.
const TERM_GRACE_SECONDS := 2.0

## Metres. The quad's height; width follows the surface aspect ratio.
const QUAD_HEIGHT := 0.6

@onready var _screen: MeshInstance3D = $Screen

var _compositor: Node = null
var _client_pid: int = -1
var _terminating_since: float = -1.0
var _material := StandardMaterial3D.new()


func _ready() -> void:
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	_screen.material_override = _material
	_screen.visible = false

	if not ClassDB.class_exists("WaylandCompositor"):
		push_warning("WaylandCompositor is not available; " +
				"build the GDExtension (see native/README.md).")
		return

	_compositor = ClassDB.instantiate("WaylandCompositor")
	add_child(_compositor)
	_compositor.surface_mapped.connect(_on_surface_mapped)
	_compositor.surface_resized.connect(_on_surface_resized)
	_compositor.surface_unmapped.connect(_on_surface_unmapped)
	_compositor.frame_available.connect(_on_frame_available)
	_compositor.client_gone.connect(_on_client_gone)

	if not _compositor.start():
		push_error("Wayland server did not start.")
		return
	_launch_client()


func _process(_delta: float) -> void:
	if _client_pid == -1:
		return
	if OS.is_process_running(_client_pid):
		_escalate_if_term_expired()
		return
	_reap_client()


## Starts the test client with a per-process environment. The socket name alone
## is not enough — without a matching XDG_RUNTIME_DIR the client cannot find it.
func _launch_client() -> void:
	var socket: String = _compositor.get_socket_name()
	var runtime_dir: String = _compositor.get_runtime_dir()
	_client_pid = OS.create_process("/usr/bin/env", [
		"XDG_RUNTIME_DIR=" + runtime_dir,
		"WAYLAND_DISPLAY=" + socket,
		CLIENT_COMMAND,
	])
	if _client_pid == -1:
		push_error("Could not spawn %s." % CLIENT_COMMAND)
		return
	print("[compositor_poc] launched %s (pid %d) on %s/%s"
			% [CLIENT_COMMAND, _client_pid, runtime_dir, socket])


func _reap_client() -> void:
	var code := OS.get_process_exit_code(_client_pid)
	_client_pid = -1
	_terminating_since = -1.0
	if code == EXIT_NOT_FOUND:
		push_error("%s is not installed; nothing will be displayed."
				% CLIENT_COMMAND)
	else:
		print("[compositor_poc] client exited with code %d" % code)


func _escalate_if_term_expired() -> void:
	if _terminating_since < 0.0:
		return
	var waited := (Time.get_ticks_msec() / 1000.0) - _terminating_since
	if waited < TERM_GRACE_SECONDS:
		return
	push_warning("%s ignored SIGTERM; sending SIGKILL." % CLIENT_COMMAND)
	OS.kill(_client_pid)
	_terminating_since = -1.0


func _stop_client() -> void:
	if _client_pid == -1:
		return
	# TERM first, then a bounded wait, then KILL. OS.kill sends SIGKILL, so the
	# polite signal has to go through the shell.
	OS.execute("kill", ["-TERM", str(_client_pid)])
	_terminating_since = Time.get_ticks_msec() / 1000.0

	var deadline := Time.get_ticks_msec() + int(TERM_GRACE_SECONDS * 1000.0)
	while Time.get_ticks_msec() < deadline and OS.is_process_running(_client_pid):
		OS.delay_msec(20)
	if OS.is_process_running(_client_pid):
		OS.kill(_client_pid)
	_reap_client()


func _exit_tree() -> void:
	_stop_client()
	if _compositor != null:
		print("[compositor_poc] stats: ", _compositor.get_stats())
		_compositor.stop()


func _on_surface_mapped(size: Vector2i) -> void:
	# No texture exists yet — binding the material here would bind null.
	print("[compositor_poc] surface mapped at %dx%d" % [size.x, size.y])
	_apply_aspect(size)


func _on_surface_resized(size: Vector2i) -> void:
	_apply_aspect(size)
	_bind_texture()


func _on_surface_unmapped() -> void:
	_screen.visible = false


func _on_frame_available() -> void:
	# First frame converted: only now is get_texture() non-null.
	_bind_texture()
	_screen.visible = true


func _on_client_gone() -> void:
	_screen.visible = false
	print("[compositor_poc] client surface went away")


func _bind_texture() -> void:
	var texture: Texture2D = _compositor.get_texture()
	if texture != null:
		_material.albedo_texture = texture


func _apply_aspect(size: Vector2i) -> void:
	if size.x <= 0 or size.y <= 0:
		return
	var mesh := _screen.mesh as QuadMesh
	if mesh == null:
		return
	var aspect := float(size.x) / float(size.y)
	mesh.size = Vector2(QUAD_HEIGHT * aspect, QUAD_HEIGHT)
