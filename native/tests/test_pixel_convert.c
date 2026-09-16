/*
 * Unit tests for bridge/pixel_convert.c.
 *
 * Plain C with no dependencies, so this runs on macOS and on the x86_64 CI
 * runner as well as in the arm64 VM -- it is the pixel path's only coverage
 * that does not need wlroots or a built GDExtension.
 *
 *     cc -O2 -Wall -Wextra -o test_pixel_convert \
 *         native/tests/test_pixel_convert.c native/bridge/pixel_convert.c
 */

#include <stdio.h>
#include <string.h>

#include "../bridge/pixel_convert.h"

static int failures = 0;


static void check(const char *label, int condition)
{
	if (condition) {
		printf("  ok   %s\n", label);
	} else {
		failures++;
		printf("  FAIL %s\n", label);
	}
}


static void check_status(const char *label, px_status got, px_status want)
{
	if (got == want) {
		printf("  ok   %s\n", label);
	} else {
		failures++;
		printf("  FAIL %s  (got %s, want %s)\n", label,
				px_status_str(got), px_status_str(want));
	}
}


/* A row of padded XRGB8888: one known pixel, then filler the copy must skip. */
static void test_swizzle_and_alpha(void)
{
	printf("[swizzle and alpha]\n");

	/* 2x2 pixels, stride padded by 8 bytes beyond the 8 a row needs. */
	const size_t stride = 16u;
	uint8_t src[2u * 16u];
	memset(src, 0xAA, sizeof(src));

	/* Pixel (0,0) = B:0x10 G:0x20 R:0x30 X:0x40 */
	src[0] = 0x10; src[1] = 0x20; src[2] = 0x30; src[3] = 0x40;
	/* Pixel (1,0) = B:0x01 G:0x02 R:0x03 X:0x04 */
	src[4] = 0x01; src[5] = 0x02; src[6] = 0x03; src[7] = 0x04;
	/* Pixel (0,1), second row starts at the stride, not at width * 4 */
	src[16] = 0x11; src[17] = 0x22; src[18] = 0x33; src[19] = 0x44;

	uint8_t dst[2u * 2u * 4u];
	memset(dst, 0, sizeof(dst));

	px_status status = px_xrgb8888_to_rgba8(src, stride, 2u, 2u, dst, sizeof(dst));
	check_status("converts a padded 2x2", status, PX_OK);

	check("pixel 0 red comes from source byte 2", dst[0] == 0x30);
	check("pixel 0 green is unmoved", dst[1] == 0x20);
	check("pixel 0 blue comes from source byte 0", dst[2] == 0x10);
	check("pixel 0 alpha is forced opaque, not the X byte", dst[3] == 0xFF);

	check("pixel 1 red", dst[4] == 0x03);
	check("pixel 1 blue", dst[6] == 0x01);

	/* Row 1 must be read from src + stride, so padding is never copied. */
	check("row 1 red is read at the stride", dst[8] == 0x33);
	check("row 1 blue is read at the stride", dst[10] == 0x11);
	check("row 1 did not pick up padding", dst[8] != 0xAA && dst[10] != 0xAA);

	check("destination is tightly packed", dst[11] == 0xFF);
}


static void test_validation(void)
{
	printf("[validation]\n");

	uint8_t src[64];
	uint8_t dst[64];
	memset(src, 0, sizeof(src));

	check_status("zero width is rejected",
			px_validate(0u, 4u, 64u), PX_ERR_DIMENSIONS);
	check_status("zero height is rejected",
			px_validate(4u, 0u, 64u), PX_ERR_DIMENSIONS);
	check_status("oversize width is rejected",
			px_validate(PX_MAX_DIMENSION + 1u, 4u, 1u << 20), PX_ERR_DIMENSIONS);
	check_status("oversize height is rejected",
			px_validate(4u, PX_MAX_DIMENSION + 1u, 64u), PX_ERR_DIMENSIONS);

	/* The case that silently reads out of bounds if it is not checked. */
	check_status("stride shorter than a row is rejected",
			px_validate(4u, 2u, 15u), PX_ERR_STRIDE);
	check_status("stride exactly a row is accepted",
			px_validate(4u, 2u, 16u), PX_OK);

	check_status("NULL source is rejected",
			px_xrgb8888_to_rgba8(NULL, 16u, 2u, 2u, dst, sizeof(dst)), PX_ERR_NULL);
	check_status("NULL destination is rejected",
			px_xrgb8888_to_rgba8(src, 16u, 2u, 2u, NULL, sizeof(dst)), PX_ERR_NULL);

	check_status("a destination one byte short is rejected",
			px_xrgb8888_to_rgba8(src, 16u, 2u, 2u, dst, 15u), PX_ERR_DST_TOO_SMALL);
}


static void test_sizes(void)
{
	printf("[size arithmetic]\n");

	size_t size = 0u;
	check_status("1x1 sizes", px_rgba_size(1u, 1u, &size), PX_OK);
	check("1x1 is 4 bytes", size == 4u);

	check_status("max dimensions still size",
			px_rgba_size(PX_MAX_DIMENSION, PX_MAX_DIMENSION, &size), PX_OK);
	check("max dimensions give the exact product",
			size == (size_t)PX_MAX_DIMENSION * PX_MAX_DIMENSION * 4u);

	check_status("zero is not a size", px_rgba_size(0u, 0u, &size), PX_ERR_DIMENSIONS);

	/* A resize must produce a different allocation, or the texture is reused wrongly. */
	size_t small = 0u, large = 0u;
	px_rgba_size(64u, 64u, &small);
	px_rgba_size(128u, 64u, &large);
	check("a width change changes the required size", small != large);
}


int main(void)
{
	test_swizzle_and_alpha();
	test_validation();
	test_sizes();

	printf("\n");
	if (failures == 0) {
		printf("PASS - all checks passed\n");
		return 0;
	}
	printf("FAIL - %d check(s) failed\n", failures);
	return 1;
}
