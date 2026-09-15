#include "wayland_compositor.h"

#include <godot_cpp/classes/global_constants.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

extern "C" {
#include "../bridge/pixel_convert.h"
}

#include <algorithm>

using namespace godot;

/*
 * wlb_set_log takes a bare function pointer with no user data, so the sink has
 * to be file-static. This proof of concept runs one compositor, so there is
 * nothing to disambiguate.
 */
static void bridge_log_sink(const char *msg)
{
	UtilityFunctions::print("[wayland] ", String(msg));
}


/*
 * Linux evdev codes are the kernel's frozen input ABI, so the literals below are
 * stable. They are written out rather than pulled from <linux/input-event-codes.h>
 * because that header's KEY_* macros collide with godot-cpp's Key enum labels of
 * the same spelling -- including it here would rewrite godot::KEY_A to a number.
 */
static constexpr uint32_t EVDEV_LEFTSHIFT = 42;
static constexpr uint32_t EVDEV_LEFTCTRL = 29;
static constexpr uint32_t EVDEV_LEFTALT = 56;
static constexpr uint32_t EVDEV_LEFTMETA = 125;
static constexpr uint32_t EVDEV_BTN_LEFT = 272;
static constexpr uint32_t EVDEV_BTN_RIGHT = 273;
static constexpr uint32_t EVDEV_BTN_MIDDLE = 274;

/* Sentinel for a Godot key with no evdev equivalent; callers drop it. */
static constexpr uint32_t EVDEV_NONE = 0;


/*
 * Maps a Godot physical key to its Linux evdev keycode. Physical, not logical:
 * the value names a position on the US layout, which is exactly what a Wayland
 * client re-interprets through its own xkb keymap. `location` disambiguates the
 * paired modifiers (left vs right Shift/Ctrl/Alt/Meta); it is ignored for keys
 * that have a single position.
 *
 * Switches on the compiler-checked Key enum so a Godot value renumbering is
 * caught at build time, and returns the frozen evdev integer. Returns
 * EVDEV_NONE for keys outside a standard 104-key keyboard plus keypad.
 */
static uint32_t physical_key_to_evdev(Key key, KeyLocation location)
{
	const bool right = location == KEY_LOCATION_RIGHT;

	switch (key) {
	/* Letters, in evdev row order rather than alphabetical. */
	case KEY_Q: return 16; case KEY_W: return 17; case KEY_E: return 18;
	case KEY_R: return 19; case KEY_T: return 20; case KEY_Y: return 21;
	case KEY_U: return 22; case KEY_I: return 23; case KEY_O: return 24;
	case KEY_P: return 25;
	case KEY_A: return 30; case KEY_S: return 31; case KEY_D: return 32;
	case KEY_F: return 33; case KEY_G: return 34; case KEY_H: return 35;
	case KEY_J: return 36; case KEY_K: return 37; case KEY_L: return 38;
	case KEY_Z: return 44; case KEY_X: return 45; case KEY_C: return 46;
	case KEY_V: return 47; case KEY_B: return 48; case KEY_N: return 49;
	case KEY_M: return 50;

	/* Number row. */
	case KEY_1: return 2; case KEY_2: return 3; case KEY_3: return 4;
	case KEY_4: return 5; case KEY_5: return 6; case KEY_6: return 7;
	case KEY_7: return 8; case KEY_8: return 9; case KEY_9: return 10;
	case KEY_0: return 11;

	/* Punctuation. */
	case KEY_MINUS: return 12; case KEY_EQUAL: return 13;
	case KEY_BRACKETLEFT: return 26; case KEY_BRACKETRIGHT: return 27;
	case KEY_BACKSLASH: return 43; case KEY_SEMICOLON: return 39;
	case KEY_APOSTROPHE: return 40; case KEY_QUOTELEFT: return 41;
	case KEY_COMMA: return 51; case KEY_PERIOD: return 52; case KEY_SLASH: return 53;

	/* Whitespace and editing. */
	case KEY_SPACE: return 57; case KEY_ENTER: return 28; case KEY_TAB: return 15;
	case KEY_BACKSPACE: return 14; case KEY_ESCAPE: return 1;

	/* Navigation and editing cluster. */
	case KEY_INSERT: return 110; case KEY_DELETE: return 111;
	case KEY_HOME: return 102; case KEY_END: return 107;
	case KEY_PAGEUP: return 104; case KEY_PAGEDOWN: return 109;
	case KEY_LEFT: return 105; case KEY_RIGHT: return 106;
	case KEY_UP: return 103; case KEY_DOWN: return 108;

	/* Locks. */
	case KEY_CAPSLOCK: return 58; case KEY_NUMLOCK: return 69;
	case KEY_SCROLLLOCK: return 70;

	/* Function row. */
	case KEY_F1: return 59; case KEY_F2: return 60; case KEY_F3: return 61;
	case KEY_F4: return 62; case KEY_F5: return 63; case KEY_F6: return 64;
	case KEY_F7: return 65; case KEY_F8: return 66; case KEY_F9: return 67;
	case KEY_F10: return 68; case KEY_F11: return 87; case KEY_F12: return 88;

	/* Paired modifiers: location picks the side, left by default. */
	case KEY_SHIFT: return right ? 54 : EVDEV_LEFTSHIFT;
	case KEY_CTRL: return right ? 97 : EVDEV_LEFTCTRL;
	case KEY_ALT: return right ? 100 : EVDEV_LEFTALT;
	case KEY_META: return right ? 126 : EVDEV_LEFTMETA;
	case KEY_MENU: return 127;

	/* Keypad. */
	case KEY_KP_0: return 82; case KEY_KP_1: return 79; case KEY_KP_2: return 80;
	case KEY_KP_3: return 81; case KEY_KP_4: return 75; case KEY_KP_5: return 76;
	case KEY_KP_6: return 77; case KEY_KP_7: return 71; case KEY_KP_8: return 72;
	case KEY_KP_9: return 73; case KEY_KP_MULTIPLY: return 55;
	case KEY_KP_DIVIDE: return 98; case KEY_KP_SUBTRACT: return 74;
	case KEY_KP_ADD: return 78; case KEY_KP_PERIOD: return 83;
	case KEY_KP_ENTER: return 96;

	default: return EVDEV_NONE;
	}
}


/* Godot MouseButton to the evdev BTN_* the pointer sends; 0 when unmapped. */
static uint32_t mouse_button_to_evdev(MouseButton button)
{
	switch (button) {
	case MOUSE_BUTTON_LEFT: return EVDEV_BTN_LEFT;
	case MOUSE_BUTTON_RIGHT: return EVDEV_BTN_RIGHT;
	case MOUSE_BUTTON_MIDDLE: return EVDEV_BTN_MIDDLE;
	default: return EVDEV_NONE;
	}
}


WaylandCompositor::WaylandCompositor()
{
}


WaylandCompositor::~WaylandCompositor()
{
	stop();
}


void WaylandCompositor::_bind_methods()
{
	ClassDB::bind_method(D_METHOD("start"), &WaylandCompositor::start);
	ClassDB::bind_method(D_METHOD("stop"), &WaylandCompositor::stop);
	ClassDB::bind_method(D_METHOD("is_running"), &WaylandCompositor::is_running);
	ClassDB::bind_method(D_METHOD("is_mapped"), &WaylandCompositor::is_mapped);
	ClassDB::bind_method(D_METHOD("get_socket_name"),
			&WaylandCompositor::get_socket_name);
	ClassDB::bind_method(D_METHOD("get_runtime_dir"),
			&WaylandCompositor::get_runtime_dir);
	ClassDB::bind_method(D_METHOD("get_wlroots_version"),
			&WaylandCompositor::get_wlroots_version);
	ClassDB::bind_method(D_METHOD("get_surface_size"),
			&WaylandCompositor::get_surface_size);
	ClassDB::bind_method(D_METHOD("get_texture"), &WaylandCompositor::get_texture);
	ClassDB::bind_method(D_METHOD("get_stats"), &WaylandCompositor::get_stats);

	ClassDB::bind_method(D_METHOD("pointer_enter", "uv"),
			&WaylandCompositor::pointer_enter);
	ClassDB::bind_method(D_METHOD("pointer_motion", "uv"),
			&WaylandCompositor::pointer_motion);
	ClassDB::bind_method(D_METHOD("pointer_leave"),
			&WaylandCompositor::pointer_leave);
	ClassDB::bind_method(D_METHOD("send_button", "button", "pressed"),
			&WaylandCompositor::send_button);
	ClassDB::bind_method(D_METHOD("send_physical_key", "event"),
			&WaylandCompositor::send_physical_key);
	ClassDB::bind_method(D_METHOD("send_virtual_key", "event"),
			&WaylandCompositor::send_virtual_key);
	ClassDB::bind_method(D_METHOD("set_keyboard_focus", "focused"),
			&WaylandCompositor::set_keyboard_focus);
	ClassDB::bind_method(D_METHOD("set_toplevel_activated", "activated"),
			&WaylandCompositor::set_toplevel_activated);
	ClassDB::bind_method(D_METHOD("set_initial_size", "size"),
			&WaylandCompositor::set_initial_size);

	ADD_SIGNAL(MethodInfo("surface_mapped",
			PropertyInfo(Variant::VECTOR2I, "size")));
	ADD_SIGNAL(MethodInfo("surface_resized",
			PropertyInfo(Variant::VECTOR2I, "size")));
	ADD_SIGNAL(MethodInfo("surface_unmapped"));
	ADD_SIGNAL(MethodInfo("frame_available"));
	ADD_SIGNAL(MethodInfo("client_gone"));
}


void WaylandCompositor::_ready()
{
	UtilityFunctions::print("[wayland] wlroots ", String(wlb_version()));
	set_process(true);
}


bool WaylandCompositor::start()
{
	char socket_buf[64] = { 0 };

	if (server != nullptr) {
		return true;
	}
	/* Installed before create so bring-up diagnostics are not lost. */
	wlb_set_log(bridge_log_sink);
	server = wlb_create(socket_buf, sizeof(socket_buf));
	if (server == nullptr) {
		UtilityFunctions::printerr("[wayland] failed to start the server");
		return false;
	}
	socket_name = String(socket_buf);
	runtime_dir = String(wlb_runtime_dir(server));
	return true;
}


void WaylandCompositor::stop()
{
	if (server == nullptr) {
		return;
	}
	wlb_destroy(server);
	server = nullptr;
	wlb_set_log(nullptr);
	socket_name = String();
	runtime_dir = String();
	image.unref();
	texture.unref();
	pixels.resize(0);
	tex_width = 0;
	tex_height = 0;
}


void WaylandCompositor::_exit_tree()
{
	stop();
}


bool WaylandCompositor::is_running() const
{
	return server != nullptr;
}


bool WaylandCompositor::is_mapped() const
{
	return server != nullptr && wlb_is_mapped(server) != 0;
}


String WaylandCompositor::get_socket_name() const
{
	return socket_name;
}


String WaylandCompositor::get_runtime_dir() const
{
	return runtime_dir;
}


String WaylandCompositor::get_wlroots_version() const
{
	return String(wlb_version());
}


Vector2i WaylandCompositor::get_surface_size() const
{
	uint32_t w = 0, h = 0;

	if (server != nullptr) {
		wlb_surface_size(server, &w, &h);
	}
	return Vector2i((int32_t)w, (int32_t)h);
}


Ref<ImageTexture> WaylandCompositor::get_texture() const
{
	return texture;
}


void WaylandCompositor::_process(double delta)
{
	if (server == nullptr) {
		return;
	}
	if (delta > slow_frame_budget) {
		/*
		 * A heuristic on Godot's own frame delta, not an OpenXR statistic. It
		 * says the frame was long; it does not say the runtime dropped it.
		 */
		slow_frames++;
	}
	wlb_poll(server);
	drain_events();
	pump_frame();
}


void WaylandCompositor::drain_events()
{
	wlb_event ev;

	while (wlb_next_event(server, &ev)) {
		switch (ev.type) {
		case WLB_EVENT_MAPPED:
			last_mapped_size = Vector2i((int32_t)ev.width, (int32_t)ev.height);
			emit_signal("surface_mapped", last_mapped_size);
			break;
		case WLB_EVENT_RESIZED:
			last_mapped_size = Vector2i((int32_t)ev.width, (int32_t)ev.height);
			emit_signal("surface_resized", last_mapped_size);
			break;
		case WLB_EVENT_UNMAPPED:
			emit_signal("surface_unmapped");
			break;
		case WLB_EVENT_CLIENT_GONE:
			emit_signal("client_gone");
			break;
		case WLB_EVENT_NONE:
		default:
			break;
		}
	}
}


/*
 * Reallocates the image, texture and staging buffer only when the surface size
 * changes. Returns false when the size is unusable, in which case nothing was
 * touched.
 */
bool WaylandCompositor::ensure_image(uint32_t width, uint32_t height)
{
	size_t needed = 0;

	if (px_rgba_size(width, height, &needed) != PX_OK) {
		return false;
	}
	if (texture.is_valid() && width == tex_width && height == tex_height) {
		return true;
	}

	pixels.resize((int64_t)needed);
	image = Image::create_from_data((int32_t)width, (int32_t)height, false,
			Image::FORMAT_RGBA8, pixels);
	if (image.is_null()) {
		return false;
	}
	if (texture.is_valid()) {
		texture->set_image(image);
	} else {
		texture = ImageTexture::create_from_image(image);
	}
	tex_width = width;
	tex_height = height;
	return texture.is_valid();
}


void WaylandCompositor::note_reject(const char *reason)
{
	frames_rejected++;
	/* Rate limited: a bad client is bad every single frame. */
	if (frames_rejected % 120 == 1) {
		UtilityFunctions::printerr("[wayland] rejected frame: ", String(reason),
				" (", frames_rejected, " so far)");
	}
}


void WaylandCompositor::pump_frame()
{
	wlb_frame frame;

	if (!wlb_frame_acquire(server, &frame)) {
		return;
	}

	/*
	 * Single exit point: every path below must reach wlb_frame_release, or the
	 * buffer stays locked and the client stalls once it runs out of its own.
	 */
	bool accepted = false;
	const uint64_t started = Time::get_singleton()->get_ticks_usec();

	px_status validated = px_validate(frame.width, frame.height, frame.stride);
	if (validated != PX_OK) {
		note_reject(px_status_str(validated));
	} else if (!ensure_image(frame.width, frame.height)) {
		note_reject("could not allocate the texture");
	} else {
		px_status converted = px_xrgb8888_to_rgba8(frame.data, frame.stride,
				frame.width, frame.height, pixels.ptrw(),
				(size_t)pixels.size());
		if (converted != PX_OK) {
			note_reject(px_status_str(converted));
		} else {
			image->set_data((int32_t)frame.width, (int32_t)frame.height, false,
					Image::FORMAT_RGBA8, pixels);
			texture->update(image);
			accepted = true;
		}
	}

	if (accepted) {
		const double elapsed_ms =
				(double)(Time::get_singleton()->get_ticks_usec() - started)
				/ 1000.0;
		record_convert_time(elapsed_ms);
		frames_copied++;
	}

	wlb_frame_release(server, accepted ? 1 : 0);
	if (accepted) {
		emit_signal("frame_available");
	}
}


void WaylandCompositor::record_convert_time(double milliseconds)
{
	/* Bounded so a long session cannot grow this without limit. */
	const int64_t max_samples = 4096;

	if (convert_samples.size() < max_samples) {
		convert_samples.push_back(milliseconds);
	} else {
		convert_samples.set(frames_copied % max_samples, milliseconds);
	}
}


Dictionary WaylandCompositor::get_stats() const
{
	Dictionary out;
	std::vector<double> sorted;

	out["frames_copied"] = frames_copied;
	out["frames_rejected"] = frames_rejected;
	out["slow_frames"] = slow_frames;
	/*
	 * The cached size rather than get_surface_size(): Godot exits children
	 * before parents, so by the time an owner prints stats from its own
	 * _exit_tree, this node's _exit_tree has already nulled the server that a
	 * live query reads through, and the answer would always be (0, 0).
	 */
	out["surface_size"] = last_mapped_size;

	for (int64_t i = 0; i < convert_samples.size(); i++) {
		sorted.push_back(convert_samples[i]);
	}
	if (sorted.empty()) {
		return out;
	}
	std::sort(sorted.begin(), sorted.end());

	/*
	 * CPU-side conversion plus the ImageTexture::update() call. update()
	 * submits the upload; it does not wait for the GPU, so this is not a
	 * measure of completed transfer.
	 */
	auto pct = [&sorted](double p) {
		size_t idx = (size_t)(p * (double)(sorted.size() - 1));
		return sorted[idx];
	};
	out["convert_submit_ms_p50"] = pct(0.50);
	out["convert_submit_ms_p95"] = pct(0.95);
	out["convert_submit_ms_p99"] = pct(0.99);
	return out;
}


/*
 * UV to surface-local pixels against the current mapped size. Not clamped: an
 * implicit grab legitimately reports coordinates outside [0, size], and the
 * bridge forwards them to the grabbing surface unchanged.
 */
void WaylandCompositor::pointer_enter(const Vector2 &uv)
{
	uint32_t w = 0, h = 0;

	if (server == nullptr) {
		return;
	}
	wlb_surface_size(server, &w, &h);
	if (w == 0 || h == 0) {
		return;
	}
	wlb_pointer_enter(server, uv.x * (double)w, uv.y * (double)h);
}


void WaylandCompositor::pointer_motion(const Vector2 &uv)
{
	uint32_t w = 0, h = 0;

	if (server == nullptr) {
		return;
	}
	wlb_surface_size(server, &w, &h);
	if (w == 0 || h == 0) {
		return;
	}
	wlb_pointer_motion(server, uv.x * (double)w, uv.y * (double)h);
}


void WaylandCompositor::pointer_leave()
{
	if (server == nullptr) {
		return;
	}
	wlb_pointer_leave(server);
}


void WaylandCompositor::send_button(int button, bool pressed)
{
	uint32_t code = mouse_button_to_evdev((MouseButton)button);

	if (server == nullptr || code == EVDEV_NONE) {
		return;
	}
	wlb_pointer_button(server, code, pressed ? 1 : 0);
}


void WaylandCompositor::send_physical_key(const Ref<InputEventKey> &event)
{
	if (server == nullptr || event.is_null() || event->is_echo()) {
		return;
	}
	uint32_t code = physical_key_to_evdev(event->get_physical_keycode(),
			event->get_location());
	if (code == EVDEV_NONE) {
		return;
	}
	wlb_keyboard_key(server, code, event->is_pressed() ? 1 : 0);
}


void WaylandCompositor::send_virtual_key(const Ref<InputEventKey> &event)
{
	/*
	 * The virtual keyboard emits a single pressed event carrying its modifier
	 * flags, with no release to follow. Hold the modifier chord across a
	 * press+release of the key, then let it go -- so the client sees a complete
	 * keystroke and no latched modifier.
	 */
	if (server == nullptr || event.is_null()) {
		return;
	}
	uint32_t code = physical_key_to_evdev(event->get_physical_keycode(),
			KEY_LOCATION_UNSPECIFIED);
	if (code == EVDEV_NONE) {
		return;
	}

	uint32_t chord[4];
	int n = 0;
	if (event->is_shift_pressed()) { chord[n++] = EVDEV_LEFTSHIFT; }
	if (event->is_ctrl_pressed()) { chord[n++] = EVDEV_LEFTCTRL; }
	if (event->is_alt_pressed()) { chord[n++] = EVDEV_LEFTALT; }
	if (event->is_meta_pressed()) { chord[n++] = EVDEV_LEFTMETA; }

	for (int i = 0; i < n; i++) {
		wlb_keyboard_key(server, chord[i], 1);
	}
	wlb_keyboard_key(server, code, 1);
	wlb_keyboard_key(server, code, 0);
	for (int i = n - 1; i >= 0; i--) {
		wlb_keyboard_key(server, chord[i], 0);
	}
}


void WaylandCompositor::set_keyboard_focus(bool focused)
{
	if (server == nullptr) {
		return;
	}
	wlb_keyboard_focus(server, focused ? 1 : 0);
}


void WaylandCompositor::set_toplevel_activated(bool activated)
{
	if (server == nullptr) {
		return;
	}
	wlb_toplevel_set_activated(server, activated ? 1 : 0);
}


void WaylandCompositor::set_initial_size(const Vector2i &size)
{
	if (server == nullptr) {
		return;
	}
	wlb_set_initial_size(server, (uint32_t)size.x, (uint32_t)size.y);
}
