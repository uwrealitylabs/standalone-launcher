#define _POSIX_C_SOURCE 200809L

#include "wl_bridge.h"

#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include <drm_fourcc.h>
#include <wayland-server-core.h>
#include <wayland-server-protocol.h>
#include <xkbcommon/xkbcommon.h>

#include <wlr/interfaces/wlr_keyboard.h>
#include <wlr/types/wlr_buffer.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_keyboard.h>
#include <wlr/types/wlr_seat.h>
#include <wlr/types/wlr_shm.h>
#include <wlr/types/wlr_xdg_decoration_v1.h>
#include <wlr/types/wlr_xdg_shell.h>
#include <wlr/util/box.h>
#include <wlr/util/log.h>
#include <wlr/util/transform.h>
#include <wlr/version.h>

#define WLB_EVENT_RING 16
#define WLB_LOG_MAX 512

/* Protocol versions we implement. Bumping these is a protocol commitment. */
#define WLB_COMPOSITOR_VERSION 6
#define WLB_SHM_VERSION 1
/* v5 is the first with xdg_toplevel.wm_capabilities, which we send empty. */
#define WLB_XDG_SHELL_VERSION 5
/* v3 carries scale, done and release; name/description (v4) are not sent. */
#define WLB_OUTPUT_VERSION 3

/*
 * Nominal geometry for the single advertised output. Nothing composites onto a
 * real screen, so the mode and physical size are placeholders; only the scale
 * (set separately) changes what a client renders.
 */
#define WLB_OUTPUT_PX_WIDTH 1920
#define WLB_OUTPUT_PX_HEIGHT 1080
#define WLB_OUTPUT_REFRESH_MHZ 60000
#define WLB_OUTPUT_MM_WIDTH 340
#define WLB_OUTPUT_MM_HEIGHT 190

/*
 * Key repeat the keyboard advertises to the client, which owns repeat from
 * here: the bridge forwards only real edges. Ordinary desktop defaults.
 */
#define WLB_REPEAT_RATE_HZ 25
#define WLB_REPEAT_DELAY_MS 600
/* evdev KEY_MAX + 1; codes at or above it are ignored. */
#define WLB_KEYCODE_LIMIT 0x300


struct wlb_server {
	struct wl_display *display;
	struct wl_event_loop *loop;
	char socket[64];
	char runtime_dir[256];
	char private_runtime_dir[256];  /* empty unless we created one */

	struct wlr_compositor *compositor;
	struct wlr_xdg_shell *xdg_shell;

	/* The SWindow header is the window's frame, so clients are told not to draw
	 * one (server-side mode). Client-side stays selectable for tests. */
	struct wlr_xdg_decoration_manager_v1 *decoration_manager;
	struct wlr_xdg_toplevel_decoration_v1 *decoration;  /* tracked toplevel's */
	int server_side_decorations;

	/* One static wl_output; a HiDPI client renders buffers output_scale times larger. */
	struct wl_global *output_global;
	struct wl_list output_resources;  /* bound, so map can send wl_surface.enter */
	int32_t output_scale;  /* 1 unless wlb_set_output_scale opts into HiDPI */

	/* One wl_seat with pointer + keyboard. Key edges go in through the seat, and
	 * the bridge owns the xkb_state that modifiers are derived from. */
	struct wlr_seat *seat;
	struct wlr_keyboard keyboard;  /* deviceless: carries only keymap + repeat_info */
	struct xkb_context *xkb_ctx;
	struct xkb_keymap *xkb_keymap;
	struct xkb_state *xkb_state;
	struct wlr_keyboard_modifiers last_mods;  /* last sent; skips redundant sends */
	unsigned char held_keys[WLB_KEYCODE_LIMIT];  /* released on focus clear */
	int seat_ready;

	/* Size the toplevel is configured with on initial commit; 0x0 = client's own. */
	uint32_t initial_width, initial_height;

	/*
	 * The bridge tracks exactly one toplevel. Later toplevels are closed rather
	 * than ignored: a surface cannot map without a conforming initial
	 * configure, so ignoring one would leave that client waiting forever.
	 */
	struct wlr_xdg_toplevel *toplevel;
	struct wlr_surface *surface;
	int mapped;
	/* Window geometry in surface-local logical units; width/height are its size. */
	struct wlr_box geometry;
	uint32_t width, height;

	/*
	 * The newest committed buffer, locked. wlroots unlocks and NULLs
	 * surface->current.buffer immediately after emitting `commit`, so this
	 * lock taken inside the commit handler is the only thing keeping the
	 * pixels alive until the copy runs. Replacing it coalesces: several
	 * commits inside one Godot frame collapse to the newest.
	 */
	struct wlr_buffer *pending;
	/* The window geometry in `pending`'s pixels; empty means the whole buffer. */
	struct wlr_box pending_crop;
	int access_open;

	wlb_event ring[WLB_EVENT_RING];
	size_t ring_head, ring_len;
	unsigned long dropped_events;
	unsigned long rejected_frames;

	struct wl_listener new_toplevel;
	struct wl_listener surface_commit;
	struct wl_listener surface_map;
	struct wl_listener surface_unmap;
	struct wl_listener surface_destroy;
	struct wl_listener xdg_surface_commit;
	struct wl_listener xdg_toplevel_destroy;
	struct wl_listener request_maximize;
	struct wl_listener request_fullscreen;
	struct wl_listener request_minimize;
	int listeners_armed;
	struct wl_listener new_decoration;
	struct wl_listener decoration_request_mode;
	struct wl_listener decoration_destroy;
};


static void (*log_cb)(const char *msg) = NULL;


void wlb_set_log(void (*cb)(const char *msg))
{
	log_cb = cb;
}


static void bridge_log(const char *fmt, ...)
{
	char buf[WLB_LOG_MAX];
	va_list ap;

	if (log_cb == NULL) {
		return;
	}
	va_start(ap, fmt);
	vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	log_cb(buf);
}


const char *wlb_version(void)
{
	return WLR_VERSION_STR;
}


const char *wlb_runtime_dir(const wlb_server *server)
{
	return server != NULL ? server->runtime_dir : "";
}


/* Queues an event for wlb_next_event, evicting the oldest when the ring is full. */
static void push_event(wlb_server *server, wlb_event_type type,
		uint32_t width, uint32_t height)
{
	size_t slot;

	if (server->ring_len == WLB_EVENT_RING) {
		/*
		 * Dropping the oldest keeps the newest state reachable. A full ring
		 * means the caller stopped draining, which is a caller bug worth
		 * counting rather than crashing over.
		 */
		server->ring_head = (server->ring_head + 1) % WLB_EVENT_RING;
		server->ring_len--;
		server->dropped_events++;
	}
	slot = (server->ring_head + server->ring_len) % WLB_EVENT_RING;
	server->ring[slot].type = type;
	server->ring[slot].width = width;
	server->ring[slot].height = height;
	server->ring_len++;
}


int wlb_next_event(wlb_server *server, wlb_event *out)
{
	if (server == NULL || out == NULL || server->ring_len == 0) {
		return 0;
	}
	*out = server->ring[server->ring_head];
	server->ring_head = (server->ring_head + 1) % WLB_EVENT_RING;
	server->ring_len--;
	return 1;
}


/* Ends any open read access to the held buffer, then unlocks and forgets it. */
static void drop_pending(wlb_server *server)
{
	if (server->pending == NULL) {
		return;
	}
	if (server->access_open) {
		wlr_buffer_end_data_ptr_access(server->pending);
		server->access_open = 0;
	}
	wlr_buffer_unlock(server->pending);
	server->pending = NULL;
}


static void send_frame_done(wlb_server *server)
{
	struct timespec now;

	if (server->surface == NULL) {
		return;
	}
	clock_gettime(CLOCK_MONOTONIC, &now);
	wlr_surface_send_frame_done(server->surface, &now);
	/*
	 * Flush now rather than leaving it to the next wlb_poll. The callback has
	 * to reach the client this frame so it can render and commit its next
	 * buffer before the next poll dispatches it; otherwise a frame-callback-
	 * paced client advances only every other Godot frame. Godot still does not
	 * consume that buffer during this _process -- the win is full-rate pacing,
	 * not same-frame turnaround.
	 */
	wl_display_flush_clients(server->display);
}


/* --- surface listeners ------------------------------------------------- */

/* Defined with the rest of the output code; the map handler needs it here. */
static void send_output_enter(wlb_server *server, struct wlr_surface *surface);
/* Defined with the seat code; the unmap and teardown paths need it here. */
static void clear_keyboard_focus(wlb_server *server);
/* Defined with the decoration code; the initial commit needs it here. */
static void apply_decoration_mode(wlb_server *server);


/*
 * The toplevel's window geometry clipped to its surface, in surface-local
 * logical units; the whole surface when the client set none that overlaps it.
 */
static struct wlr_box window_geometry(const wlb_server *server)
{
	const struct wlr_surface *surface = server->surface;
	struct wlr_box bounds = {0, 0, 0, 0};
	struct wlr_box geometry;

	if (surface == NULL) {
		return bounds;
	}
	bounds.width = surface->current.width > 0 ? surface->current.width : 0;
	bounds.height = surface->current.height > 0 ? surface->current.height : 0;
	/* wlroots already defaults an unset geometry to the surface extents. */
	if (server->toplevel == NULL || !wlr_box_intersection(&geometry,
			&server->toplevel->base->geometry, &bounds)) {
		return bounds;
	}
	return geometry;
}


/*
 * Maps a surface-local box into buffer pixels: scaled, then through the
 * buffer transform. Empty under wp_viewporter, whose mapping is not modelled.
 */
static struct wlr_box surface_to_buffer_box(const struct wlr_surface_state *state,
		const struct wlr_box *box)
{
	struct wlr_box scaled = *box;
	struct wlr_box out = {0, 0, 0, 0};

	if (state->viewport.has_src || state->viewport.has_dst) {
		return out;
	}
	scaled.x *= state->scale;
	scaled.y *= state->scale;
	scaled.width *= state->scale;
	scaled.height *= state->scale;
	/* The extents are the box's own space: the surface, scaled to pixels. */
	wlr_box_transform(&out, &scaled, wlr_output_transform_invert(state->transform),
			state->width * state->scale, state->height * state->scale);
	return out;
}


/*
 * Tracks the mapped window geometry, reporting size changes as RESIZED, and
 * locks each newly committed buffer as the frame wlb_frame_acquire hands out.
 */
static void handle_surface_commit(struct wl_listener *listener, void *data)
{
	wlb_server *server = wl_container_of(listener, server, surface_commit);
	struct wlr_surface *surface = server->surface;
	struct wlr_box geometry;

	(void)data;
	if (surface == NULL) {
		return;
	}

	/* Logical units, not buffer pixels (scale 2: a 1612x982 buffer is 806x491),
	 * since input divides by them. The xdg role has already applied the geometry. */
	geometry = window_geometry(server);
	if (server->mapped) {
		server->geometry = geometry;
		if ((uint32_t)geometry.width != server->width
				|| (uint32_t)geometry.height != server->height) {
			server->width = (uint32_t)geometry.width;
			server->height = (uint32_t)geometry.height;
			push_event(server, WLB_EVENT_RESIZED, server->width, server->height);
		}
	}

	if (surface->current.buffer == NULL) {
		return;
	}

	/*
	 * Lock here or lose it: surface_commit_state unlocks and NULLs
	 * current.buffer as soon as this signal returns.
	 */
	drop_pending(server);
	server->pending = wlr_buffer_lock(surface->current.buffer);
	server->pending_crop = surface_to_buffer_box(&surface->current, &geometry);
}


static void handle_surface_map(struct wl_listener *listener, void *data)
{
	wlb_server *server = wl_container_of(listener, server, surface_map);
	struct wlr_surface *surface = server->surface;

	(void)data;
	server->mapped = 1;
	/* Logical units, matching handle_surface_commit -- see the note there. */
	server->geometry = window_geometry(server);
	server->width = (uint32_t)server->geometry.width;
	server->height = (uint32_t)server->geometry.height;
	send_output_enter(server, surface);
	bridge_log("surface mapped: %ux%u at %d,%d in a %dx%d surface", server->width,
			server->height, server->geometry.x, server->geometry.y,
			surface != NULL ? surface->current.width : 0,
			surface != NULL ? surface->current.height : 0);
	push_event(server, WLB_EVENT_MAPPED, server->width, server->height);
}


static void handle_surface_unmap(struct wl_listener *listener, void *data)
{
	wlb_server *server = wl_container_of(listener, server, surface_unmap);

	(void)data;
	server->mapped = 0;
	drop_pending(server);
	/* Drop input focus defensively; a surface no client can see must not stay
	 * the pointer or keyboard target. */
	if (server->seat != NULL) {
		wlr_seat_pointer_notify_clear_focus(server->seat);
	}
	clear_keyboard_focus(server);
	bridge_log("surface unmapped");
	push_event(server, WLB_EVENT_UNMAPPED, 0, 0);
}


/* Unhooks every per-client listener. A no-op once they are already unhooked. */
static void detach_surface(wlb_server *server)
{
	if (!server->listeners_armed) {
		return;
	}
	wl_list_remove(&server->surface_commit.link);
	wl_list_remove(&server->surface_map.link);
	wl_list_remove(&server->surface_unmap.link);
	wl_list_remove(&server->surface_destroy.link);
	wl_list_remove(&server->xdg_surface_commit.link);
	wl_list_remove(&server->xdg_toplevel_destroy.link);
	wl_list_remove(&server->request_maximize.link);
	wl_list_remove(&server->request_fullscreen.link);
	wl_list_remove(&server->request_minimize.link);
	server->listeners_armed = 0;
}


/*
 * Full client-gone cleanup, shared by the wl_surface-destroy and
 * xdg_toplevel-destroy paths. Idempotent: whichever destroy signal fires first
 * runs this and detaches every listener, so the second becomes a no-op and
 * CLIENT_GONE is pushed exactly once.
 */
static void teardown_client(wlb_server *server)
{
	if (!server->listeners_armed) {
		return;
	}
	drop_pending(server);
	detach_surface(server);
	if (server->seat != NULL) {
		wlr_seat_pointer_notify_clear_focus(server->seat);
	}
	clear_keyboard_focus(server);
	server->surface = NULL;
	server->toplevel = NULL;
	server->mapped = 0;
	server->geometry = (struct wlr_box){0, 0, 0, 0};
	server->width = 0;
	server->height = 0;
	bridge_log("tracked toplevel removed");
	push_event(server, WLB_EVENT_CLIENT_GONE, 0, 0);
}


static void handle_surface_destroy(struct wl_listener *listener, void *data)
{
	wlb_server *server = wl_container_of(listener, server, surface_destroy);

	(void)data;
	teardown_client(server);
}


/*
 * The xdg_toplevel role object can be destroyed while its wl_surface lives on.
 * wlroots frees the wlr_xdg_toplevel right after this signal, so tearing down
 * here is what keeps server->toplevel (and the xdg_surface commit listener that
 * dereferences it) from outliving the object.
 */
static void handle_xdg_toplevel_destroy(struct wl_listener *listener, void *data)
{
	wlb_server *server = wl_container_of(listener, server,
			xdg_toplevel_destroy);

	(void)data;
	teardown_client(server);
}


/*
 * Nothing can be maximized or fullscreened, but xdg-shell requires a configure
 * in reply to a set or unset request; an unchanged one answers both. Before the
 * initial commit the initial configure is that reply. `wanted` is set vs unset.
 */
static void decline_state_request(wlb_server *server, const char *what, bool wanted)
{
	/* An unset needs no declining: the state is already off. */
	bridge_log(wanted ? "declined %s request" : "acknowledged un%s request", what);
	if (server->toplevel != NULL && server->toplevel->base->initialized) {
		wlr_xdg_surface_schedule_configure(server->toplevel->base);
	}
}


static void handle_request_maximize(struct wl_listener *listener, void *data)
{
	wlb_server *server = wl_container_of(listener, server, request_maximize);

	(void)data;
	decline_state_request(server, "maximize", server->toplevel->requested.maximized);
}


static void handle_request_fullscreen(struct wl_listener *listener, void *data)
{
	wlb_server *server = wl_container_of(listener, server, request_fullscreen);

	(void)data;
	decline_state_request(server, "fullscreen", server->toplevel->requested.fullscreen);
}


/* Minimize needs no reply; the client simply stays visible. */
static void handle_request_minimize(struct wl_listener *listener, void *data)
{
	wlb_server *server = wl_container_of(listener, server, request_minimize);

	(void)data;
	bridge_log("declined minimize request");
}


static void handle_xdg_surface_commit(struct wl_listener *listener, void *data)
{
	wlb_server *server = wl_container_of(listener, server, xdg_surface_commit);

	(void)data;
	if (server->toplevel == NULL || !server->toplevel->base->initial_commit) {
		return;
	}
	/* Configure the slot size before the first buffer maps; the default 0x0
	 * lets the client keep the size it chose. */
	wlr_xdg_toplevel_set_size(server->toplevel, server->initial_width,
			server->initial_height);
	/* wlroots advertises every capability by default; an empty set tells the
	 * client its maximize/fullscreen/minimize buttons and window menu do nothing. */
	wlr_xdg_toplevel_set_wm_capabilities(server->toplevel, 0);
	bridge_log("wm capabilities: none advertised");
	/* A decoration created before this commit could not be answered yet. */
	apply_decoration_mode(server);
	/* wl_compositor v6 HiDPI, set now so the first buffer is already scaled.
	 * Legacy toolkits ignore it and use the wl_output.enter sent on map. */
	wlr_surface_set_preferred_buffer_scale(server->surface,
			server->output_scale);
}


/*
 * Adopts the first toplevel and arms its listeners; any toplevel arriving while
 * one is held is asked to close.
 */
static void handle_new_toplevel(struct wl_listener *listener, void *data)
{
	wlb_server *server = wl_container_of(listener, server, new_toplevel);
	struct wlr_xdg_toplevel *toplevel = data;

	if (server->toplevel != NULL) {
		bridge_log("rejecting extra toplevel: compositor shows one window");
		wlr_xdg_toplevel_send_close(toplevel);
		return;
	}

	server->toplevel = toplevel;
	server->surface = toplevel->base->surface;

	server->surface_commit.notify = handle_surface_commit;
	wl_signal_add(&server->surface->events.commit, &server->surface_commit);
	server->surface_map.notify = handle_surface_map;
	wl_signal_add(&server->surface->events.map, &server->surface_map);
	server->surface_unmap.notify = handle_surface_unmap;
	wl_signal_add(&server->surface->events.unmap, &server->surface_unmap);
	server->surface_destroy.notify = handle_surface_destroy;
	wl_signal_add(&server->surface->events.destroy, &server->surface_destroy);
	server->xdg_surface_commit.notify = handle_xdg_surface_commit;
	wl_signal_add(&server->surface->events.commit, &server->xdg_surface_commit);
	server->xdg_toplevel_destroy.notify = handle_xdg_toplevel_destroy;
	wl_signal_add(&toplevel->events.destroy, &server->xdg_toplevel_destroy);
	server->request_maximize.notify = handle_request_maximize;
	wl_signal_add(&toplevel->events.request_maximize, &server->request_maximize);
	server->request_fullscreen.notify = handle_request_fullscreen;
	wl_signal_add(&toplevel->events.request_fullscreen,
			&server->request_fullscreen);
	server->request_minimize.notify = handle_request_minimize;
	wl_signal_add(&toplevel->events.request_minimize, &server->request_minimize);
	server->listeners_armed = 1;

	bridge_log("toplevel accepted");
}


/* --- decorations -------------------------------------------------------- */

static const char *decoration_mode_name(enum wlr_xdg_toplevel_decoration_v1_mode mode)
{
	switch (mode) {
	case WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE:
		return "client-side";
	case WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE:
		return "server-side";
	default:
		return "none";
	}
}


/*
 * Sends the tracked decoration our mode whatever the client asked for. Waits
 * for the initial commit, since wlroots asserts on configuring before it.
 */
static void apply_decoration_mode(wlb_server *server)
{
	struct wlr_xdg_toplevel_decoration_v1 *decoration = server->decoration;
	enum wlr_xdg_toplevel_decoration_v1_mode mode = server->server_side_decorations
			? WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE
			: WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE;

	if (decoration == NULL || !decoration->toplevel->base->initialized) {
		return;
	}
	wlr_xdg_toplevel_decoration_v1_set_mode(decoration, mode);
	bridge_log("decoration mode: %s (client requested %s)",
			decoration_mode_name(mode),
			decoration_mode_name(decoration->requested_mode));
}


/* Unhooks the tracked decoration's listeners. A no-op when none is tracked. */
static void detach_decoration(wlb_server *server)
{
	if (server->decoration == NULL) {
		return;
	}
	wl_list_remove(&server->decoration_request_mode.link);
	wl_list_remove(&server->decoration_destroy.link);
	server->decoration = NULL;
}


static void handle_decoration_request_mode(struct wl_listener *listener, void *data)
{
	wlb_server *server = wl_container_of(listener, server,
			decoration_request_mode);

	(void)data;
	apply_decoration_mode(server);
}


static void handle_decoration_destroy(struct wl_listener *listener, void *data)
{
	wlb_server *server = wl_container_of(listener, server, decoration_destroy);

	(void)data;
	detach_decoration(server);
	bridge_log("decoration destroyed");
}


/* Tracks the decoration of the tracked toplevel; any other toplevel is closing. */
static void handle_new_decoration(struct wl_listener *listener, void *data)
{
	wlb_server *server = wl_container_of(listener, server, new_decoration);
	struct wlr_xdg_toplevel_decoration_v1 *decoration = data;

	if (decoration->toplevel != server->toplevel || server->decoration != NULL) {
		return;
	}
	server->decoration = decoration;
	server->decoration_request_mode.notify = handle_decoration_request_mode;
	wl_signal_add(&decoration->events.request_mode,
			&server->decoration_request_mode);
	server->decoration_destroy.notify = handle_decoration_destroy;
	wl_signal_add(&decoration->events.destroy, &server->decoration_destroy);
	bridge_log("decoration created");
	apply_decoration_mode(server);
}


/* --- runtime directory and socket -------------------------------------- */

/* A usable XDG_RUNTIME_DIR is ours, a directory, and not group/world writable. */
static int runtime_dir_ok(const char *path)
{
	struct stat st;

	if (path == NULL || path[0] != '/') {
		return 0;
	}
	if (stat(path, &st) != 0 || !S_ISDIR(st.st_mode)) {
		return 0;
	}
	if (st.st_uid != getuid()) {
		return 0;
	}
	return (st.st_mode & (S_IRWXG | S_IRWXO)) == 0;
}


/*
 * Resolves the directory the socket will live in. Prefers an inherited, valid
 * XDG_RUNTIME_DIR, which is the normal case on the VM and the board; otherwise
 * creates a private 0700 directory and records it for removal at shutdown.
 */
static int resolve_runtime_dir(wlb_server *server)
{
	const char *env = getenv("XDG_RUNTIME_DIR");
	char candidate[256];

	if (runtime_dir_ok(env)) {
		snprintf(server->runtime_dir, sizeof(server->runtime_dir), "%s", env);
		return 1;
	}

	snprintf(candidate, sizeof(candidate), "/tmp/wayland-godot-%d",
			(int)getpid());
	if (mkdir(candidate, 0700) != 0 && errno != EEXIST) {
		bridge_log("cannot create runtime dir %s: %s", candidate,
				strerror(errno));
		return 0;
	}
	if (!runtime_dir_ok(candidate)) {
		bridge_log("created runtime dir %s but it is not usable", candidate);
		return 0;
	}
	snprintf(server->runtime_dir, sizeof(server->runtime_dir), "%s", candidate);
	snprintf(server->private_runtime_dir, sizeof(server->private_runtime_dir),
			"%s", candidate);
	bridge_log("XDG_RUNTIME_DIR unusable; created %s", candidate);
	return 1;
}


/*
 * libwayland reads XDG_RUNTIME_DIR from the environment, so a private directory
 * has to be exported across wl_display_add_socket and restored immediately.
 * Leaving it set would redirect every process the launcher later spawns.
 */
static int bind_socket(wlb_server *server)
{
	char saved[256];
	int had_saved = 0;
	const char *env;
	int rc = 0;

	env = getenv("XDG_RUNTIME_DIR");
	if (env != NULL) {
		snprintf(saved, sizeof(saved), "%s", env);
		had_saved = 1;
	}
	if (setenv("XDG_RUNTIME_DIR", server->runtime_dir, 1) != 0) {
		bridge_log("setenv XDG_RUNTIME_DIR failed: %s", strerror(errno));
		return 0;
	}

	for (int attempt = 0; attempt < 32; attempt++) {
		if (attempt == 0) {
			snprintf(server->socket, sizeof(server->socket),
					"wayland-godot-%d", (int)getpid());
		} else {
			snprintf(server->socket, sizeof(server->socket),
					"wayland-godot-%d-%d", (int)getpid(), attempt);
		}
		if (wl_display_add_socket(server->display, server->socket) == 0) {
			rc = 1;
			break;
		}
	}
	if (!rc) {
		bridge_log("could not bind a wayland socket in %s", server->runtime_dir);
		server->socket[0] = '\0';
	}

	if (had_saved) {
		setenv("XDG_RUNTIME_DIR", saved, 1);
	} else {
		unsetenv("XDG_RUNTIME_DIR");
	}
	return rc;
}


/* --- seat / input ------------------------------------------------------- */

/*
 * The keyboard carries only a name; it never has LEDs to update. wlroots guards
 * the NULL led_update, and the bridge never calls wlr_keyboard_led_update.
 */
static const struct wlr_keyboard_impl wlb_keyboard_impl = {
	.name = "wlb-virtual-keyboard",
};


/*
 * The single input timestamp source. Wayland wants a monotonic millisecond
 * clock shared across pointer and keyboard; wraparound at ~49 days is harmless,
 * clients treat these as opaque and only compare them.
 */
static uint32_t now_msec(void)
{
	struct timespec now;

	clock_gettime(CLOCK_MONOTONIC, &now);
	return (uint32_t)(now.tv_sec * 1000 + now.tv_nsec / 1000000);
}


/* The modifier and layout mask the bridge's xkb state currently implies. */
static struct wlr_keyboard_modifiers current_mods(wlb_server *server)
{
	struct wlr_keyboard_modifiers mods = {
		.depressed = xkb_state_serialize_mods(server->xkb_state,
				XKB_STATE_MODS_DEPRESSED),
		.latched = xkb_state_serialize_mods(server->xkb_state,
				XKB_STATE_MODS_LATCHED),
		.locked = xkb_state_serialize_mods(server->xkb_state,
				XKB_STATE_MODS_LOCKED),
		.group = xkb_state_serialize_layout(server->xkb_state,
				XKB_STATE_LAYOUT_EFFECTIVE),
	};
	return mods;
}


/* Sends a wl_keyboard.modifiers only when the mask actually changed. */
static void sync_modifiers(wlb_server *server)
{
	struct wlr_keyboard_modifiers mods = current_mods(server);

	if (mods.depressed == server->last_mods.depressed
			&& mods.latched == server->last_mods.latched
			&& mods.locked == server->last_mods.locked
			&& mods.group == server->last_mods.group) {
		return;
	}
	server->last_mods = mods;
	wlr_seat_keyboard_notify_modifiers(server->seat, &mods);
}


/*
 * Clears keyboard focus and releases every held key from xkb_state. The host
 * stops forwarding keys once focus goes, so a modifier held across the clear
 * would never see its release and would stay applied on the next enter.
 */
static void clear_keyboard_focus(wlb_server *server)
{
	if (!server->seat_ready) {
		return;
	}
	wlr_seat_keyboard_notify_clear_focus(server->seat);
	for (uint32_t code = 0; code < WLB_KEYCODE_LIMIT; code++) {
		if (server->held_keys[code]) {
			server->held_keys[code] = 0;
			xkb_state_update_key(server->xkb_state, code + 8, XKB_KEY_UP);
		}
	}
	/* No client has focus, so this only brings last_mods up to date. */
	sync_modifiers(server);
}


/*
 * Frees the xkb objects and finishes the keyboard. The wlr_seat itself is owned
 * by the display and torn down with it, so it is not destroyed here. Idempotent.
 */
static void destroy_seat(wlb_server *server)
{
	if (server->seat_ready) {
		wlr_keyboard_finish(&server->keyboard);
		server->seat_ready = 0;
	}
	if (server->xkb_state != NULL) {
		xkb_state_unref(server->xkb_state);
		server->xkb_state = NULL;
	}
	if (server->xkb_keymap != NULL) {
		xkb_keymap_unref(server->xkb_keymap);
		server->xkb_keymap = NULL;
	}
	if (server->xkb_ctx != NULL) {
		xkb_context_unref(server->xkb_ctx);
		server->xkb_ctx = NULL;
	}
}


/*
 * Builds the seat, a default (us) xkb keymap and the deviceless keyboard that
 * advertises it. A keymap that fails to compile would crash the client on
 * focus, so it is validated here and creation fails instead. Returns 1 on
 * success; on failure the partial state is freed and 0 returned.
 */
static int setup_seat(wlb_server *server)
{
	struct xkb_rule_names rules = { 0 };

	server->seat = wlr_seat_create(server->display, "seat0");
	if (server->seat == NULL) {
		bridge_log("wlr_seat_create failed");
		return 0;
	}

	server->xkb_ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
	if (server->xkb_ctx == NULL) {
		bridge_log("xkb_context_new failed");
		return 0;
	}
	server->xkb_keymap = xkb_keymap_new_from_names(server->xkb_ctx, &rules,
			XKB_KEYMAP_COMPILE_NO_FLAGS);
	if (server->xkb_keymap == NULL) {
		bridge_log("xkb_keymap_new_from_names failed");
		return 0;
	}
	server->xkb_state = xkb_state_new(server->xkb_keymap);
	if (server->xkb_state == NULL) {
		bridge_log("xkb_state_new failed");
		return 0;
	}

	wlr_keyboard_init(&server->keyboard, &wlb_keyboard_impl,
			wlb_keyboard_impl.name);
	if (!wlr_keyboard_set_keymap(&server->keyboard, server->xkb_keymap)) {
		bridge_log("wlr_keyboard_set_keymap rejected the keymap");
		wlr_keyboard_finish(&server->keyboard);
		return 0;
	}
	server->seat_ready = 1;
	wlr_keyboard_set_repeat_info(&server->keyboard, WLB_REPEAT_RATE_HZ,
			WLB_REPEAT_DELAY_MS);
	wlr_seat_set_keyboard(server->seat, &server->keyboard);
	wlr_seat_set_capabilities(server->seat,
			WL_SEAT_CAPABILITY_POINTER | WL_SEAT_CAPABILITY_KEYBOARD);
	return 1;
}


/* --- output ------------------------------------------------------------- */

static void output_handle_release(struct wl_client *client,
		struct wl_resource *resource)
{
	(void)client;
	wl_resource_destroy(resource);
}


static const struct wl_output_interface output_impl = {
	.release = output_handle_release,
};


static void output_resource_destroy(struct wl_resource *resource)
{
	wl_list_remove(wl_resource_get_link(resource));
}


/*
 * wl_output bind: advertise one fixed-mode output and its current scale. The
 * geometry and mode are nominal; the scale is what a HiDPI client acts on, and
 * the wl_surface.enter sent on map (send_output_enter) is what ties the surface
 * to this output so the client reads that scale.
 */
static void output_bind(struct wl_client *client, void *data,
		uint32_t version, uint32_t id)
{
	wlb_server *server = data;
	struct wl_resource *resource = wl_resource_create(client,
			&wl_output_interface, (int)version, id);

	if (resource == NULL) {
		wl_client_post_no_memory(client);
		return;
	}
	wl_resource_set_implementation(resource, &output_impl, server,
			output_resource_destroy);
	wl_list_insert(&server->output_resources, wl_resource_get_link(resource));

	wl_output_send_geometry(resource, 0, 0, WLB_OUTPUT_MM_WIDTH,
			WLB_OUTPUT_MM_HEIGHT, WL_OUTPUT_SUBPIXEL_UNKNOWN,
			"WRL", "compositor", WL_OUTPUT_TRANSFORM_NORMAL);
	if (version >= WL_OUTPUT_SCALE_SINCE_VERSION) {
		wl_output_send_scale(resource, server->output_scale);
	}
	wl_output_send_mode(resource,
			WL_OUTPUT_MODE_CURRENT | WL_OUTPUT_MODE_PREFERRED,
			WLB_OUTPUT_PX_WIDTH, WLB_OUTPUT_PX_HEIGHT, WLB_OUTPUT_REFRESH_MHZ);
	if (version >= WL_OUTPUT_DONE_SINCE_VERSION) {
		wl_output_send_done(resource);
	}
	/*
	 * send_output_enter only fires on map, so a client that binds this output
	 * after mapping would never hear the enter. Send it now for that case.
	 */
	if (server->mapped && server->surface != NULL
			&& server->surface->resource != NULL
			&& wl_resource_get_client(server->surface->resource) == client) {
		wl_surface_send_enter(server->surface->resource, resource);
	}
}


/*
 * Enter every output the surface's client bound. With one output this is the
 * signal a toolkit waits for before it trusts the output's scale, so a client
 * that connected before wlb_set_output_scale still redraws at the right size.
 */
static void send_output_enter(wlb_server *server, struct wlr_surface *surface)
{
	struct wl_client *client;
	struct wl_resource *output;

	if (surface == NULL || surface->resource == NULL) {
		return;
	}
	client = wl_resource_get_client(surface->resource);
	wl_resource_for_each(output, &server->output_resources) {
		if (wl_resource_get_client(output) == client) {
			wl_surface_send_enter(surface->resource, output);
		}
	}
}


/* --- lifecycle ---------------------------------------------------------- */

wlb_server *wlb_create(char *socket_out, size_t socket_len)
{
	/* wlr_shm_create asserts unless both are listed. Both are accepted and
	 * rendered opaque; see wlb_frame_acquire. */
	static const uint32_t formats[] = {
		DRM_FORMAT_ARGB8888,
		DRM_FORMAT_XRGB8888,
	};
	wlb_server *server;

	wlr_log_init(WLR_ERROR, NULL);

	server = calloc(1, sizeof(*server));
	if (server == NULL) {
		return NULL;
	}

	server->display = wl_display_create();
	if (server->display == NULL) {
		bridge_log("wl_display_create failed");
		free(server);
		return NULL;
	}
	server->loop = wl_display_get_event_loop(server->display);

	if (!resolve_runtime_dir(server) || !bind_socket(server)) {
		goto fail;
	}

	/*
	 * NULL renderer: Godot does the rendering, so wlroots never needs to build
	 * textures. The cost is that surface->buffer stays NULL and the bridge must
	 * read surface->current.buffer instead.
	 */
	server->compositor = wlr_compositor_create(server->display,
			WLB_COMPOSITOR_VERSION, NULL);
	if (wlr_shm_create(server->display, WLB_SHM_VERSION, formats,
			sizeof(formats) / sizeof(formats[0])) == NULL) {
		bridge_log("wlr_shm_create failed");
		goto fail;
	}
	server->xdg_shell = wlr_xdg_shell_create(server->display,
			WLB_XDG_SHELL_VERSION);
	if (server->compositor == NULL || server->xdg_shell == NULL) {
		bridge_log("compositor or xdg-shell creation failed");
		goto fail;
	}
	server->server_side_decorations = 1;
	server->decoration_manager =
			wlr_xdg_decoration_manager_v1_create(server->display);
	if (server->decoration_manager == NULL) {
		bridge_log("xdg-decoration manager creation failed");
		goto fail;
	}

	if (!setup_seat(server)) {
		bridge_log("seat setup failed");
		goto fail;
	}

	/* Scale 1 is the client's own resolution. The list must exist before the
	 * first bind, which cannot happen until a client connects after this returns. */
	wl_list_init(&server->output_resources);
	server->output_scale = 1;
	server->output_global = wl_global_create(server->display,
			&wl_output_interface, WLB_OUTPUT_VERSION, server, output_bind);
	if (server->output_global == NULL) {
		bridge_log("wl_output global creation failed");
		goto fail;
	}

	/*
	 * Attached last, once nothing can fail: xdg-shell and xdg-decoration assert
	 * on destroy if a listener is still attached, so wlb_destroy removes each
	 * only when set.
	 */
	server->new_toplevel.notify = handle_new_toplevel;
	wl_signal_add(&server->xdg_shell->events.new_toplevel,
			&server->new_toplevel);
	server->new_decoration.notify = handle_new_decoration;
	wl_signal_add(&server->decoration_manager->events.new_toplevel_decoration,
			&server->new_decoration);

	if (socket_out != NULL && socket_len > 0) {
		snprintf(socket_out, socket_len, "%s", server->socket);
	}
	bridge_log("wayland server up on %s/%s (wlroots %s)",
			server->runtime_dir, server->socket, wlb_version());
	return server;

fail:
	/* wlb_destroy tolerates a partly built server, including the runtime dir. */
	wlb_destroy(server);
	return NULL;
}


void wlb_poll(wlb_server *server)
{
	if (server == NULL) {
		return;
	}
	/* Zero timeout, always: this runs on the frame thread. */
	wl_event_loop_dispatch(server->loop, 0);
	wl_display_flush_clients(server->display);
}


int wlb_is_mapped(const wlb_server *server)
{
	return server != NULL && server->mapped;
}


void wlb_surface_size(const wlb_server *server, uint32_t *width, uint32_t *height)
{
	if (width != NULL) {
		*width = server != NULL ? server->width : 0;
	}
	if (height != NULL) {
		*height = server != NULL ? server->height : 0;
	}
}


int wlb_frame_acquire(wlb_server *server, wlb_frame *out)
{
	void *data = NULL;
	uint32_t format = 0;
	size_t stride = 0;
	struct wlr_box bounds, crop;

	if (server == NULL || out == NULL || server->pending == NULL
			|| server->access_open) {
		return 0;
	}

	if (!wlr_buffer_begin_data_ptr_access(server->pending,
			WLR_BUFFER_DATA_PTR_ACCESS_READ, &data, &format, &stride)) {
		/*
		 * Not readable as shared memory -- a dmabuf, most likely. Drop it and
		 * still answer the frame callback, or the client stops drawing.
		 */
		bridge_log("buffer is not CPU-readable; dropping frame");
		drop_pending(server);
		send_frame_done(server);
		return 0;
	}

	/* Alpha is forced to 0xFF, so ARGB (Cairo, e.g. weston-terminal) renders as XRGB
	 * and translucency comes out dark. Rate-limited: a bad format repeats per frame. */
	if (format != DRM_FORMAT_XRGB8888 && format != DRM_FORMAT_ARGB8888) {
		wlr_buffer_end_data_ptr_access(server->pending);
		if (server->rejected_frames % 120 == 0) {
			bridge_log("rejecting frame: format 0x%08x is not XRGB8888 or "
					"ARGB8888 (%lu rejected so far)", format,
					server->rejected_frames + 1);
		}
		server->rejected_frames++;
		drop_pending(server);
		send_frame_done(server);
		return 0;
	}

	/* Clamp to the buffer: the crop came from surface state the buffer may not match. */
	bounds = (struct wlr_box){0, 0, server->pending->width, server->pending->height};
	if (!wlr_box_intersection(&crop, &server->pending_crop, &bounds)) {
		crop = bounds;
	}

	server->access_open = 1;
	out->data = (const uint8_t *)data + (size_t)crop.y * stride + (size_t)crop.x * 4;
	out->width = (uint32_t)crop.width;
	out->height = (uint32_t)crop.height;
	out->stride = stride;
	out->drm_format = format;
	return 1;
}


void wlb_frame_release(wlb_server *server, int accepted)
{
	(void)accepted;
	if (server == NULL || !server->access_open) {
		return;
	}
	wlr_buffer_end_data_ptr_access(server->pending);
	server->access_open = 0;
	wlr_buffer_unlock(server->pending);
	server->pending = NULL;
	/* Sent whether or not the pixels were used: silence freezes the client. */
	send_frame_done(server);
}


/* --- input -------------------------------------------------------------- */

void wlb_pointer_enter(wlb_server *server, double sx, double sy)
{
	if (server == NULL || server->seat == NULL || server->surface == NULL) {
		return;
	}
	/* Unlike the raw motion/button sends, notify_enter already sends its own
	 * wl_pointer.frame, so the bridge must not add a second one. */
	wlr_seat_pointer_notify_enter(server->seat, server->surface,
			sx + server->geometry.x, sy + server->geometry.y);
}


void wlb_pointer_motion(wlb_server *server, double sx, double sy)
{
	if (server == NULL || server->seat == NULL) {
		return;
	}
	wlr_seat_pointer_notify_motion(server->seat, now_msec(),
			sx + server->geometry.x, sy + server->geometry.y);
	wlr_seat_pointer_notify_frame(server->seat);
}


void wlb_pointer_leave(wlb_server *server)
{
	if (server == NULL || server->seat == NULL) {
		return;
	}
	/* Deferred while a button is held: wlroots' implicit grab keeps the
	 * pressed surface focused until release, which is the behaviour we want. */
	wlr_seat_pointer_notify_clear_focus(server->seat);
	wlr_seat_pointer_notify_frame(server->seat);
}


void wlb_pointer_button(wlb_server *server, uint32_t button, int pressed)
{
	if (server == NULL || server->seat == NULL) {
		return;
	}
	wlr_seat_pointer_notify_button(server->seat, now_msec(), button,
			pressed ? WL_POINTER_BUTTON_STATE_PRESSED
					: WL_POINTER_BUTTON_STATE_RELEASED);
	wlr_seat_pointer_notify_frame(server->seat);
}


void wlb_keyboard_key(wlb_server *server, uint32_t keycode, int pressed)
{
	if (server == NULL || !server->seat_ready || keycode >= WLB_KEYCODE_LIMIT) {
		return;
	}
	/* A key held across a focus clear was already released there. */
	if (!pressed && !server->held_keys[keycode]) {
		return;
	}
	server->held_keys[keycode] = pressed ? 1 : 0;
	wlr_seat_keyboard_notify_key(server->seat, now_msec(), keycode,
			pressed ? WL_KEYBOARD_KEY_STATE_PRESSED
					: WL_KEYBOARD_KEY_STATE_RELEASED);
	/* xkb keycode = evdev + 8. Updating after the key sends a modifier press
	 * as a key event first, then the mask that later keys apply. */
	xkb_state_update_key(server->xkb_state, keycode + 8,
			pressed ? XKB_KEY_DOWN : XKB_KEY_UP);
	sync_modifiers(server);
}


void wlb_keyboard_focus(wlb_server *server, int focused)
{
	if (server == NULL || !server->seat_ready) {
		return;
	}
	if (focused && server->surface != NULL) {
		struct wlr_keyboard_modifiers mods = current_mods(server);

		/* No keys are tracked as held across a focus change. */
		wlr_seat_keyboard_notify_enter(server->seat, server->surface,
				NULL, 0, &mods);
		server->last_mods = mods;
	} else {
		clear_keyboard_focus(server);
	}
}


void wlb_toplevel_set_activated(wlb_server *server, int activated)
{
	if (server == NULL || server->toplevel == NULL) {
		return;
	}
	/* wlroots asserts on configuring an uninitialized surface (before the
	 * initial commit, or after a null-buffer unmap); the host resends on map. */
	if (!server->toplevel->base->initialized) {
		return;
	}
	wlr_xdg_toplevel_set_activated(server->toplevel, activated);
}


void wlb_set_initial_size(wlb_server *server, uint32_t width, uint32_t height)
{
	if (server == NULL) {
		return;
	}
	server->initial_width = width;
	server->initial_height = height;
}


void wlb_set_server_side_decorations(wlb_server *server, int enabled)
{
	if (server == NULL) {
		return;
	}
	server->server_side_decorations = enabled ? 1 : 0;
	apply_decoration_mode(server);
}


void wlb_set_output_scale(wlb_server *server, int32_t scale)
{
	struct wl_resource *output;

	if (server == NULL || scale < 1) {
		return;
	}
	server->output_scale = scale;
	/* Runtime scale change for a live v6 surface; a surface not yet committed
	 * gets it in handle_xdg_surface_commit instead. */
	if (server->surface != NULL) {
		wlr_surface_set_preferred_buffer_scale(server->surface, scale);
	}
	/* Push the scale plus a done (applied atomically) to bound clients; later
	 * binds read it in output_bind. */
	wl_resource_for_each(output, &server->output_resources) {
		if (wl_resource_get_version(output) >= WL_OUTPUT_SCALE_SINCE_VERSION) {
			wl_output_send_scale(output, scale);
		}
		if (wl_resource_get_version(output) >= WL_OUTPUT_DONE_SINCE_VERSION) {
			wl_output_send_done(output);
		}
	}
}


void wlb_destroy(wlb_server *server)
{
	if (server == NULL) {
		return;
	}
	if (server->dropped_events > 0) {
		bridge_log("dropped %lu events: caller did not drain the queue",
				server->dropped_events);
	}

	drop_pending(server);
	detach_surface(server);
	detach_decoration(server);
	if (server->new_toplevel.notify != NULL) {
		wl_list_remove(&server->new_toplevel.link);
	}
	if (server->new_decoration.notify != NULL) {
		wl_list_remove(&server->new_decoration.link);
	}
	/* Stop new binds; existing output resources are freed with their clients. */
	if (server->output_global != NULL) {
		wl_global_destroy(server->output_global);
	}

	/*
	 * Clients first. Destroying the display while a client still holds a
	 * buffer we own is a use-after-free.
	 */
	if (server->display != NULL) {
		wl_display_destroy_clients(server->display);
	}
	/* Finish the keyboard and free xkb before the display goes: the display
	 * destroys the seat, which must first drop its reference to the keyboard. */
	destroy_seat(server);
	if (server->display != NULL) {
		wl_display_destroy(server->display);
	}

	if (server->private_runtime_dir[0] != '\0') {
		char path[512];

		snprintf(path, sizeof(path), "%s/%s", server->private_runtime_dir,
				server->socket);
		unlink(path);
		snprintf(path, sizeof(path), "%s/%s.lock", server->private_runtime_dir,
				server->socket);
		unlink(path);
		rmdir(server->private_runtime_dir);
	}

	free(server);
}
