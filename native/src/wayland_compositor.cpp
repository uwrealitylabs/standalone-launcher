#include "wayland_compositor.h"

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
