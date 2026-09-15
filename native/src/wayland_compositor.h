#ifndef WAYLAND_COMPOSITOR_H
#define WAYLAND_COMPOSITOR_H

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/classes/input_event_key.hpp>
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector2i.hpp>

extern "C" {
#include "../bridge/wl_bridge.h"
}

namespace godot {

/*
 * Runs a one-window Wayland server and publishes the client's pixels as an
 * ImageTexture.
 *
 * Owns polling and the texture, and nothing else: the client process belongs
 * to GDScript (see project/compositor/compositor_poc.gd).
 *
 * Bind the texture on `frame_available`, never on `surface_mapped` -- a
 * surface maps before any buffer has been converted, so get_texture() is still
 * null at that point.
 */
class WaylandCompositor : public Node {
	GDCLASS(WaylandCompositor, Node)

public:
	WaylandCompositor();
	~WaylandCompositor();

	void _ready() override;
	void _process(double delta) override;
	void _exit_tree() override;

	bool start();
	void stop();

	bool is_running() const;
	bool is_mapped() const;
	String get_socket_name() const;
	String get_runtime_dir() const;
	String get_wlroots_version() const;
	Vector2i get_surface_size() const;
	Ref<ImageTexture> get_texture() const;
	Dictionary get_stats() const;

	/*
	 * --- input: GDScript drives the hosted toplevel through these ------------
	 *
	 * The boundary converts to Wayland's model so callers stay in Godot terms:
	 * pointer position is normalized surface UV (0..1 across the mapped size,
	 * and may fall outside it during an implicit grab); buttons are Godot
	 * MouseButton; keys are InputEventKey. All are no-ops until a surface maps.
	 */
	void pointer_enter(const Vector2 &uv);
	void pointer_motion(const Vector2 &uv);
	void pointer_leave();
	void send_button(int button, bool pressed);

	/*
	 * A real key event: translated 1:1, press/release and left/right location
	 * preserved. Echo (auto-repeat) events are dropped -- Wayland clients
	 * generate their own repeats from the advertised repeat_info.
	 */
	void send_physical_key(const Ref<InputEventKey> &event);

	/*
	 * A virtual-keyboard tap, which arrives as a single pressed event with its
	 * modifier flags. Expanded at the boundary into the modifier chord, the key
	 * press and release, and the modifier release, since no real release follows.
	 */
	void send_virtual_key(const Ref<InputEventKey> &event);

	void set_keyboard_focus(bool focused);
	void set_toplevel_activated(bool activated);
	void set_initial_size(const Vector2i &size);

protected:
	static void _bind_methods();

private:
	void drain_events();
	void pump_frame();
	bool ensure_image(uint32_t width, uint32_t height);
	void record_convert_time(double milliseconds);
	void note_reject(const char *reason);

	wlb_server *server = nullptr;
	String socket_name;
	String runtime_dir;

	Ref<Image> image;
	Ref<ImageTexture> texture;
	PackedByteArray pixels;
	uint32_t tex_width = 0;
	uint32_t tex_height = 0;

	/*
	 * Kept sorted-on-read rather than on-write: a few thousand samples cost
	 * nothing to sort once in get_stats(), and sorting per frame would defeat
	 * the point of measuring the frame.
	 */
	PackedFloat64Array convert_samples;

	/*
	 * Last size a map or resize event reported. Deliberately survives unmap
	 * and stop(), because get_stats() is read during teardown. Callers who
	 * want the size right now want get_surface_size().
	 */
	Vector2i last_mapped_size;
	int64_t frames_copied = 0;
	int64_t frames_rejected = 0;
	int64_t slow_frames = 0;
	double slow_frame_budget = 1.0 / 72.0;
};

} // namespace godot

#endif // WAYLAND_COMPOSITOR_H
