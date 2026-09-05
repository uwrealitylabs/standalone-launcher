extends Node3D

const COMPOSITOR_SCREEN_PATH := "WindowManager/CompositorScreen"

var xr_interface: XRInterface

## Set once a close request is being handled, so repeated requests (a second
## close while the graceful teardown is still in flight) are ignored.
var _quitting: bool = false

func _ready():
	# Intercept the quit request so the compositor can tear its client and server
	# down on frames before the tree is freed; see _notification.
	get_tree().auto_accept_quit = false

	xr_interface = XRServer.find_interface("OpenXR")
	if xr_interface and xr_interface.is_initialized():
		print("OpenXR initialized successfully")

		# Turn off v-sync!
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)

		# Change our main viewport to output to the HMD
		get_viewport().use_xr = true
	else:
		print("OpenXR not initialized, please check if your headset is connected")


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_shutdown_and_quit()


## Runs the compositor's frame-driven shutdown, then quits. Awaiting
## shutdown_finished keeps rendering alive through the client's grace period
## instead of blocking on teardown. The screen emits that signal even when it has
## nothing to stop, so the await never hangs on hosts without the compositor.
func _shutdown_and_quit() -> void:
	if _quitting:
		return
	_quitting = true
	var screen := get_node_or_null(COMPOSITOR_SCREEN_PATH)
	if screen != null and screen.has_method("request_shutdown"):
		screen.request_shutdown()
		await screen.shutdown_finished
	get_tree().quit()
