/*
 * Shared-memory pixel conversion for the Wayland compositor bridge.
 *
 * Deliberately free of wlroots, libwayland and Godot headers: this unit is the
 * only part of the native path that can be compiled and unit-tested on any
 * host, including the macOS development machines, where wlroots does not exist.
 * Keep it that way -- it is the project's only portable coverage of the pixel
 * path.
 */

#ifndef WRL_PIXEL_CONVERT_H
#define WRL_PIXEL_CONVERT_H

#include <stddef.h>
#include <stdint.h>

/*
 * Upper bound on either surface edge. Bounds the destination allocation and
 * keeps the width * height * 4 product far inside size_t on 32-bit builds; a
 * client asking for more is rejected rather than trusted.
 */
#define PX_MAX_DIMENSION 8192u

typedef enum {
	PX_OK = 0,
	PX_ERR_NULL,        /* src or dst pointer was NULL */
	PX_ERR_DIMENSIONS,  /* zero, or larger than PX_MAX_DIMENSION */
	PX_ERR_STRIDE,      /* source stride cannot hold one row of pixels */
	PX_ERR_OVERFLOW,    /* width * height * 4 is not representable */
	PX_ERR_DST_TOO_SMALL,
} px_status;

/* Human-readable form of `status`, for logs. Never NULL. */
const char *px_status_str(px_status status);

/*
 * Bytes required to hold `width` x `height` pixels as RGBA8.
 * Writes *out only on PX_OK.
 */
px_status px_rgba_size(uint32_t width, uint32_t height, size_t *out);

/*
 * Checks a client-supplied buffer description without reading it. Callers
 * should run this before mapping or trusting any of the values.
 */
px_status px_validate(uint32_t width, uint32_t height, size_t src_stride);

/*
 * Converts XRGB8888 to Godot's Image::FORMAT_RGBA8.
 *
 * Source bytes are little-endian XRGB8888, which in memory order is B, G, R, X;
 * the destination wants R, G, B, A. The X byte carries no meaning, so alpha is
 * forced opaque rather than copied.
 *
 * `src_stride` is the byte distance between source rows and is usually larger
 * than width * 4; the destination is always tightly packed. Returns PX_OK only
 * when every pixel was written.
 */
px_status px_xrgb8888_to_rgba8(const uint8_t *src, size_t src_stride,
		uint32_t width, uint32_t height, uint8_t *dst, size_t dst_len);

#endif /* WRL_PIXEL_CONVERT_H */
