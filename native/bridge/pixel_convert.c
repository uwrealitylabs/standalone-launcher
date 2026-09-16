#include "pixel_convert.h"


const char *px_status_str(px_status status)
{
	switch (status) {
	case PX_OK:            return "ok";
	case PX_ERR_NULL:      return "null pointer";
	case PX_ERR_DIMENSIONS: return "bad dimensions";
	case PX_ERR_STRIDE:    return "stride shorter than a row";
	case PX_ERR_OVERFLOW:  return "size overflow";
	case PX_ERR_DST_TOO_SMALL: return "destination too small";
	}
	return "unknown";
}


px_status px_rgba_size(uint32_t width, uint32_t height, size_t *out)
{
	if (width == 0u || height == 0u ||
			width > PX_MAX_DIMENSION || height > PX_MAX_DIMENSION) {
		return PX_ERR_DIMENSIONS;
	}

	/*
	 * Bounded above by PX_MAX_DIMENSION, so this cannot wrap -- but the check
	 * is written out rather than argued, because the bound is a constant
	 * someone may raise later without revisiting this line.
	 */
	size_t pixels = (size_t)width * (size_t)height;
	if (pixels / (size_t)width != (size_t)height) {
		return PX_ERR_OVERFLOW;
	}
	if (pixels > (size_t)-1 / 4u) {
		return PX_ERR_OVERFLOW;
	}

	if (out != NULL) {
		*out = pixels * 4u;
	}
	return PX_OK;
}


px_status px_validate(uint32_t width, uint32_t height, size_t src_stride)
{
	px_status status = px_rgba_size(width, height, NULL);
	if (status != PX_OK) {
		return status;
	}
	/* A row of pixels must fit in the stride the client reported. */
	if (src_stride < (size_t)width * 4u) {
		return PX_ERR_STRIDE;
	}
	return PX_OK;
}


px_status px_xrgb8888_to_rgba8(const uint8_t *src, size_t src_stride,
		uint32_t width, uint32_t height, uint8_t *dst, size_t dst_len)
{
	if (src == NULL || dst == NULL) {
		return PX_ERR_NULL;
	}

	px_status status = px_validate(width, height, src_stride);
	if (status != PX_OK) {
		return status;
	}

	size_t needed = 0u;
	status = px_rgba_size(width, height, &needed);
	if (status != PX_OK) {
		return status;
	}
	if (dst_len < needed) {
		return PX_ERR_DST_TOO_SMALL;
	}

	for (uint32_t y = 0u; y < height; ++y) {
		const uint8_t *in = src + (size_t)y * src_stride;
		uint8_t *out = dst + (size_t)y * (size_t)width * 4u;

		for (uint32_t x = 0u; x < width; ++x) {
			/* in: B G R X  ->  out: R G B A */
			out[0] = in[2];
			out[1] = in[1];
			out[2] = in[0];
			out[3] = 0xFFu;
			in += 4;
			out += 4;
		}
	}

	return PX_OK;
}
