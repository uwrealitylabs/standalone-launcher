/*
 * wl_bridge -- the only place wlroots types are allowed to exist.
 *
 * Scope: one Wayland server, one xdg_toplevel, wl_shm buffers copied to
 * the caller. No input, no resize negotiation, no popups, no subsurfaces.
 *
 * The API deliberately carries state and events rather than only frames: the
 * caller has no way to see a wlr_surface, so mapping, resizing and client exit
 * have to arrive as plain data.
 *
 * Threading: none. Every call must come from the same thread, which for the
 * launcher is Godot's main thread. wlroots documents shared-memory buffer
 * access as not thread-safe.
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
	WLB_EVENT_FRAME,        /* a new buffer is pending; acquire it */
	WLB_EVENT_CLIENT_GONE,
} wlb_event_type;


typedef struct {
	wlb_event_type type;
	uint32_t width, height;
} wlb_event;


/*
 * A read window onto a locked buffer. Valid only between a successful
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

/* Last known surface size in pixels; zero when nothing is mapped. */
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
 * Tears down clients, then the display, then bridge-owned buffers and the
 * socket. `server` is invalid afterwards. Passing NULL is a no-op.
 */
void wlb_destroy(wlb_server *server);

#ifdef __cplusplus
}
#endif

#endif /* WL_BRIDGE_H */
