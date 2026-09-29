/*
 * wl_bridge -- the only place wlroots types may exist. One server, one
 * xdg_toplevel, copied wl_shm buffers and a pointer + keyboard seat; no popups or
 * subsurfaces. Map, resize and client exit arrive as plain-data events.
 * Single-threaded: every call from one thread (Godot's main), as wlroots shm
 * buffer access is not thread-safe.
 */
#ifndef WL_BRIDGE_H
#define WL_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct wlb_server wlb_server;


typedef enum {
	WLB_EVENT_NONE = 0,
	WLB_EVENT_MAPPED,       /* width/height valid */
	WLB_EVENT_UNMAPPED,
	WLB_EVENT_RESIZED,      /* width/height valid */
	WLB_EVENT_CLIENT_GONE,
} wlb_event_type;


typedef struct {
	wlb_event_type type;
	uint32_t width, height;
} wlb_event;


/*
 * A read window onto a locked buffer, sized in buffer pixels (the logical size
 * times the client's buffer scale). Valid only between a successful
 * wlb_frame_acquire() and the matching wlb_frame_release(); `data` dangles
 * after release.
 */
typedef struct {
	const uint8_t *data;
	uint32_t width, height;
	size_t stride;
	uint32_t drm_format;
} wlb_frame;


/* Version string of the wlroots the bridge was built against. Never NULL. */
const char *wlb_version(void);

/*
 * Installs a log sink used for every bridge diagnostic. Pass NULL to silence.
 * Safe to call before wlb_create, and that is the intended order -- diagnostics
 * emitted during creation are otherwise lost.
 */
void wlb_set_log(void (*cb)(const char *msg));

/*
 * Creates the display, socket and globals. On success writes the socket name
 * (e.g. "wayland-godot-1234") into `socket_out` and returns the server.
 * Returns NULL on failure, having released everything it allocated.
 */
wlb_server *wlb_create(char *socket_out, size_t socket_len);

/*
 * Directory the socket was created in. A client needs both this as
 * XDG_RUNTIME_DIR and the socket name as WAYLAND_DISPLAY; the socket name alone
 * is not enough to find it. Never NULL after a successful wlb_create.
 */
const char *wlb_runtime_dir(const wlb_server *server);

/*
 * Dispatches pending Wayland events with a zero timeout and flushes clients.
 * Never blocks. Call once per frame before draining events.
 */
void wlb_poll(wlb_server *server);

/* Pops one queued event. Returns 1 while events remain, 0 when drained. */
int wlb_next_event(wlb_server *server, wlb_event *out);

/* Whether the selected toplevel is currently mapped. */
int wlb_is_mapped(const wlb_server *server);

/*
 * Last known logical surface size -- the buffer size divided by the client's
 * buffer scale; zero when nothing is mapped.
 */
void wlb_surface_size(const wlb_server *server, uint32_t *width, uint32_t *height);

/*
 * Opens a read window onto the newest committed buffer. Returns 1 and fills
 * `out` when a buffer has been committed since the last accepted frame, 0
 * otherwise (an idle client therefore costs nothing).
 *
 * Every successful acquire must be paired with exactly one wlb_frame_release.
 * Holding the window open stalls the client once its own buffers run out, so
 * release as soon as the copy is done.
 */
int wlb_frame_acquire(wlb_server *server, wlb_frame *out);

/*
 * Closes the read window opened by wlb_frame_acquire and completes the client's
 * frame callback. Pass accepted=1 when the pixels were consumed, 0 when they
 * were rejected; the frame callback is sent either way, because a client that
 * never hears back stops drawing.
 */
void wlb_frame_release(wlb_server *server, int accepted);

/*
 * Pointer input in surface-local logical units (see wlb_surface_size). Each call
 * ends with exactly one pointer frame, so the caller never sends one. A press
 * starts an implicit grab: motion and release reach the surface even outside it.
 */
void wlb_pointer_enter(wlb_server *server, double sx, double sy);
void wlb_pointer_motion(wlb_server *server, double sx, double sy);
void wlb_pointer_leave(wlb_server *server);
void wlb_pointer_button(wlb_server *server, uint32_t button, int pressed);

/*
 * Keys are evdev codes, real edges only (the client makes its own repeats); the
 * bridge derives modifiers, and a release for a key not held is ignored. Focus
 * drives wl_keyboard enter/leave and gates delivery; losing it releases held keys.
 */
void wlb_keyboard_key(wlb_server *server, uint32_t keycode, int pressed);
void wlb_keyboard_focus(wlb_server *server, int focused);

/* xdg_toplevel activated state; the client uses it to render focus. */
void wlb_toplevel_set_activated(wlb_server *server, int activated);

/*
 * Logical size the bridge configures the toplevel with on its initial
 * commit -- set it before the client maps so the first buffer arrives at the
 * slot size. 0x0 (the default) lets the client keep the size it chooses.
 */
void wlb_set_initial_size(wlb_server *server, uint32_t width, uint32_t height);

/*
 * xdg-decoration mode sent to every client that asks: nonzero (the default)
 * tells it not to draw its own title bar, zero lets it. Applies to a live
 * client immediately.
 */
void wlb_set_server_side_decorations(wlb_server *server, int enabled);

/*
 * wl_output scale: a HiDPI client renders scale-times more pixels, for legible
 * text at distance. Default 1; values below 1 are ignored. Safe after clients
 * bind -- the new scale is pushed to them.
 */
void wlb_set_output_scale(wlb_server *server, int32_t scale);

/*
 * Tears down clients, then the display, then bridge-owned buffers and the
 * socket. `server` is invalid afterwards. Passing NULL is a no-op.
 */
void wlb_destroy(wlb_server *server);

#ifdef __cplusplus
}
#endif

#endif /* WL_BRIDGE_H */
