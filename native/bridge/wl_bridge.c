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

#include <wlr/types/wlr_buffer.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_shm.h>
#include <wlr/types/wlr_xdg_shell.h>
#include <wlr/util/log.h>
#include <wlr/version.h>

#define WLB_EVENT_RING 16
#define WLB_LOG_MAX 512

/* Protocol versions we implement. Bumping these is a protocol commitment. */
#define WLB_COMPOSITOR_VERSION 6
#define WLB_SHM_VERSION 1
#define WLB_XDG_SHELL_VERSION 3


struct wlb_server {
	struct wl_display *display;
	struct wl_event_loop *loop;
	char socket[64];
	char runtime_dir[256];
	char private_runtime_dir[256];  /* empty unless we created one */

	struct wlr_compositor *compositor;
	struct wlr_xdg_shell *xdg_shell;

	/*
	 * Card 1 tracks exactly one toplevel. Later toplevels are closed rather
	 * than ignored: a surface cannot map without a conforming initial
	 * configure, so ignoring one would leave that client waiting forever.
	 */
	struct wlr_xdg_toplevel *toplevel;
	struct wlr_surface *surface;
	int mapped;
	uint32_t width, height;

	/*
	 * The newest committed buffer, locked. wlroots unlocks and NULLs
	 * surface->current.buffer immediately after emitting `commit`, so this
	 * lock taken inside the commit handler is the only thing keeping the
	 * pixels alive until the copy runs. Replacing it coalesces: several
	 * commits inside one Godot frame collapse to the newest.
	 */
	struct wlr_buffer *pending;
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
	int listeners_armed;
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
}


/* --- surface listeners ------------------------------------------------- */

static void handle_surface_commit(struct wl_listener *listener, void *data)
{
	wlb_server *server = wl_container_of(listener, server, surface_commit);
	struct wlr_surface *surface = server->surface;
	uint32_t w, h;

	(void)data;
	if (surface == NULL) {
		return;
	}

	w = (uint32_t)(surface->current.buffer_width > 0 ?
			surface->current.buffer_width : 0);
	h = (uint32_t)(surface->current.buffer_height > 0 ?
			surface->current.buffer_height : 0);
	if (server->mapped && (w != server->width || h != server->height)) {
		server->width = w;
		server->height = h;
		push_event(server, WLB_EVENT_RESIZED, w, h);
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
	push_event(server, WLB_EVENT_FRAME, w, h);
}


static void handle_surface_map(struct wl_listener *listener, void *data)
{
	wlb_server *server = wl_container_of(listener, server, surface_map);
	struct wlr_surface *surface = server->surface;

	(void)data;
	server->mapped = 1;
	if (surface != NULL) {
		server->width = (uint32_t)(surface->current.buffer_width > 0 ?
				surface->current.buffer_width : 0);
		server->height = (uint32_t)(surface->current.buffer_height > 0 ?
				surface->current.buffer_height : 0);
	}
	bridge_log("surface mapped: %ux%u", server->width, server->height);
	push_event(server, WLB_EVENT_MAPPED, server->width, server->height);
}


static void handle_surface_unmap(struct wl_listener *listener, void *data)
{
	wlb_server *server = wl_container_of(listener, server, surface_unmap);

	(void)data;
	server->mapped = 0;
	drop_pending(server);
	bridge_log("surface unmapped");
	push_event(server, WLB_EVENT_UNMAPPED, 0, 0);
}


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
	server->listeners_armed = 0;
}


static void handle_surface_destroy(struct wl_listener *listener, void *data)
{
	wlb_server *server = wl_container_of(listener, server, surface_destroy);

	(void)data;
	drop_pending(server);
	detach_surface(server);
	server->surface = NULL;
	server->toplevel = NULL;
	server->mapped = 0;
	server->width = 0;
	server->height = 0;
	bridge_log("surface destroyed");
	push_event(server, WLB_EVENT_CLIENT_GONE, 0, 0);
}


static void handle_xdg_surface_commit(struct wl_listener *listener, void *data)
{
	wlb_server *server = wl_container_of(listener, server, xdg_surface_commit);

	(void)data;
	if (server->toplevel == NULL || !server->toplevel->base->initial_commit) {
		return;
	}
	/* 0x0 lets the client keep the size it already chose. */
	wlr_xdg_toplevel_set_size(server->toplevel, 0, 0);
}


static void handle_new_toplevel(struct wl_listener *listener, void *data)
{
	wlb_server *server = wl_container_of(listener, server, new_toplevel);
	struct wlr_xdg_toplevel *toplevel = data;

	if (server->toplevel != NULL) {
		bridge_log("rejecting extra toplevel: Card 1 shows one window");
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
	server->listeners_armed = 1;

	bridge_log("toplevel accepted");
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


/* --- lifecycle ---------------------------------------------------------- */

wlb_server *wlb_create(char *socket_out, size_t socket_len)
{
	/*
	 * wl_shm requires both of these unconditionally -- wlr_shm_create asserts
	 * on a list missing either. ARGB is therefore advertised but rejected at
	 * acquire time; see wlb_frame_acquire.
	 */
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
		wl_display_destroy(server->display);
		free(server);
		return NULL;
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
		wl_display_destroy(server->display);
		free(server);
		return NULL;
	}
	server->xdg_shell = wlr_xdg_shell_create(server->display,
			WLB_XDG_SHELL_VERSION);
	if (server->compositor == NULL || server->xdg_shell == NULL) {
		bridge_log("compositor or xdg-shell creation failed");
		wl_display_destroy(server->display);
		free(server);
		return NULL;
	}

	server->new_toplevel.notify = handle_new_toplevel;
	wl_signal_add(&server->xdg_shell->events.new_toplevel,
			&server->new_toplevel);

	if (socket_out != NULL && socket_len > 0) {
		snprintf(socket_out, socket_len, "%s", server->socket);
	}
	bridge_log("wayland server up on %s/%s (wlroots %s)",
			server->runtime_dir, server->socket, wlb_version());
	return server;
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

	/*
	 * Wayland ARGB8888 is premultiplied, which StandardMaterial3D does not
	 * expect, so Card 1 renders XRGB only. Rejecting here rather than rendering
	 * something subtly wrong; the log is rate-limited because a client that
	 * picks ARGB picks it every frame.
	 */
	if (format != DRM_FORMAT_XRGB8888) {
		wlr_buffer_end_data_ptr_access(server->pending);
		if (server->rejected_frames % 120 == 0) {
			bridge_log("rejecting frame: format 0x%08x is not XRGB8888 "
					"(%lu rejected so far)", format,
					server->rejected_frames + 1);
		}
		server->rejected_frames++;
		drop_pending(server);
		send_frame_done(server);
		return 0;
	}

	server->access_open = 1;
	out->data = (const uint8_t *)data;
	out->width = (uint32_t)server->pending->width;
	out->height = (uint32_t)server->pending->height;
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
	if (server->xdg_shell != NULL) {
		wl_list_remove(&server->new_toplevel.link);
	}

	/*
	 * Clients first. Destroying the display while a client still holds a
	 * buffer we own is a use-after-free.
	 */
	if (server->display != NULL) {
		wl_display_destroy_clients(server->display);
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
