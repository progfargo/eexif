/* JPEG preview decoding with stb_image (baseline and progressive JPEG).
 *
 * The image is decoded at full size, resampled with a box filter to fit
 * the preview area, and rotated/mirrored according to the EXIF
 * orientation. This file is always compiled with optimizations (see
 * build.zig) because decoding large photos is slow at -O0.
 */
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_JPEG
#define STBI_NO_STDIO
#define STBI_NO_HDR
#define STBI_NO_LINEAR
#include "stb_image.h"
#include "lvgl.h"

/* Photos larger than this (in pixels) are not previewed */
#define MAX_PIXELS (200u * 1000u * 1000u)

/* Maps pixel (u, v) of a w x h stored image to display coordinates. */
static void orient(int o, int u, int v, int w, int h, int * x, int * y)
{
    switch (o) {
        case 2: *x = w - 1 - u; *y = v; break;
        case 3: *x = w - 1 - u; *y = h - 1 - v; break;
        case 4: *x = u; *y = h - 1 - v; break;
        case 5: *x = v; *y = u; break;
        case 6: *x = h - 1 - v; *y = u; break;
        case 7: *x = h - 1 - v; *y = w - 1 - u; break;
        case 8: *x = v; *y = w - 1 - u; break;
        default: *x = u; *y = v; break;
    }
}

/* Decodes JPEG data into a new XRGB8888 draw buffer that fits in
 * max_w x max_h after applying the EXIF orientation (1-8; anything else
 * means normal). The image is only scaled down, never up.
 * Writes the full stored size to *orig_w / *orig_h.
 * Returns NULL if the data cannot be decoded (e.g. CMYK or corrupt). */
lv_draw_buf_t * eexif_decode_preview(const unsigned char * data, size_t len, int max_w, int max_h,
                                     int orientation, int * orig_w, int * orig_h)
{
    int sw, sh, comp;
    if (max_w < 1 || max_h < 1 || len > 0x7FFFFFFF) return NULL;
    if (!stbi_info_from_memory(data, (int)len, &sw, &sh, &comp)) return NULL;
    *orig_w = sw;
    *orig_h = sh;
    if ((unsigned long long)sw * (unsigned long long)sh > MAX_PIXELS) return NULL;

    unsigned char * pixels = stbi_load_from_memory(data, (int)len, &sw, &sh, &comp, 3);
    if (!pixels) return NULL;

    /* Fit box in stored (unrotated) orientation */
    const int swap = orientation >= 5 && orientation <= 8;
    const int fit_w = swap ? max_h : max_w;
    const int fit_h = swap ? max_w : max_h;

    /* Target size in stored orientation (downscale only, keep aspect) */
    double s = 1.0;
    if ((double)fit_w / sw < s) s = (double)fit_w / sw;
    if ((double)fit_h / sh < s) s = (double)fit_h / sh;
    int tw = (int)(sw * s);
    int th = (int)(sh * s);
    if (tw < 1) tw = 1;
    if (th < 1) th = 1;

    const int dw = swap ? th : tw;
    const int dh = swap ? tw : th;
    lv_draw_buf_t * buf = lv_draw_buf_create((uint32_t)dw, (uint32_t)dh, LV_COLOR_FORMAT_XRGB8888, LV_STRIDE_AUTO);
    if (!buf) {
        stbi_image_free(pixels);
        return NULL;
    }
    const uint32_t stride = buf->header.stride;

    /* Box filter: each target pixel averages its source footprint */
    for (int v = 0; v < th; v++) {
        const int y0 = (int)((long long)v * sh / th);
        int y1 = (int)((long long)(v + 1) * sh / th);
        if (y1 <= y0) y1 = y0 + 1;
        for (int u = 0; u < tw; u++) {
            const int x0 = (int)((long long)u * sw / tw);
            int x1 = (int)((long long)(u + 1) * sw / tw);
            if (x1 <= x0) x1 = x0 + 1;
            unsigned r = 0, g = 0, b = 0, n = 0;
            for (int yy = y0; yy < y1; yy++) {
                const unsigned char * p = pixels + ((size_t)yy * sw + x0) * 3;
                for (int xx = x0; xx < x1; xx++, p += 3) {
                    r += p[0];
                    g += p[1];
                    b += p[2];
                    n++;
                }
            }
            int x, y;
            orient(orientation, u, v, tw, th, &x, &y);
            uint32_t * dst = (uint32_t *)(buf->data + (size_t)y * stride) + x;
            *dst = 0xFF000000u | ((r / n) << 16) | ((g / n) << 8) | (b / n);
        }
    }
    stbi_image_free(pixels);
    return buf;
}
