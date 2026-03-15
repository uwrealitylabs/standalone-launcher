class_name XRUtils

static func is_openxr_active() -> bool:
	var xr_interface: XRInterface = XRServer.find_interface("OpenXR")
	if xr_interface:
		return xr_interface.is_initialized() and xr_interface.is_primary()
	return false
