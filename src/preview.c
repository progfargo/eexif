/* JPEG preview decoding with libjpeg(-turbo).
 *
 * libjpeg reports errors through longjmp, which Zig code must not be
 * unwound by, so decoding lives in C. The image is decoded at a reduced
 * scale (1/2 .. 1/8) when it is much larger than the preview area, then
 * resampled to fit and rotated/mirrored according to the EXIF orientation.
 */
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <jpeglib.h>
#include "lvgl.h"

struct err_mgr {
    struct jpeg_error_mgr pub;
    jmp_buf jump;
};

static void on_error(j_common_ptr cinfo)
{
    struct err_mgr * e = (struct err_mgr *)cinfo->err;
    longjmp(e->jump, 1);
}

static void on_message(j_common_ptr cinfo)
{
    (void)cinfo; /* warnings about corrupt data are not printed */
}

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
    struct jpeg_decompress_struct cinfo;
    struct err_mgr jerr;
    unsigned char * volatile pixels = NULL;
    lv_draw_buf_t * volatile buf = NULL;

    if (max_w < 1 || max_h < 1) return NULL;

    cinfo.err = jpeg_std_error(&jerr.pub);
    jerr.pub.error_exit = on_error;
    jerr.pub.output_message = on_message;
    if (setjmp(jerr.jump)) {
        jpeg_destroy_decompress(&cinfo);
        free(pixels);
        if (buf) lv_draw_buf_destroy(buf);
        return NULL;
    }

    jpeg_create_decompress(&cinfo);
    jpeg_mem_src(&cinfo, data, (unsigned long)len);
    jpeg_read_header(&cinfo, TRUE);
    *orig_w = (int)cinfo.image_width;
    *orig_h = (int)cinfo.image_height;

    /* Fit box in stored (unrotated) orientation */
    const int swap = orientation >= 5 && orientation <= 8;
    const int fit_w = swap ? max_h : max_w;
    const int fit_h = swap ? max_w : max_h;

    /* Largest decoder downscale that still keeps at least the fit size */
    unsigned int denom = 1;
    while (denom < 8 && cinfo.image_width / (denom * 2) >= (unsigned)fit_w &&
           cinfo.image_height / (denom * 2) >= (unsigned)fit_h)
        denom *= 2;
    cinfo.scale_num = 1;
    cinfo.scale_denom = denom;
    cinfo.out_color_space = JCS_RGB;
    jpeg_start_decompress(&cinfo);

    const int sw = (int)cinfo.output_width;
    const int sh = (int)cinfo.output_height;
    pixels = malloc((size_t)sw * (size_t)sh * 3);
    if (!pixels) longjmp(jerr.jump, 1);
    while (cinfo.output_scanline < cinfo.output_height) {
        JSAMPROW row = pixels + (size_t)cinfo.output_scanline * (size_t)sw * 3;
        jpeg_read_scanlines(&cinfo, &row, 1);
    }
    jpeg_finish_decompress(&cinfo);
    jpeg_destroy_decompress(&cinfo);

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
    buf = lv_draw_buf_create((uint32_t)dw, (uint32_t)dh, LV_COLOR_FORMAT_XRGB8888, LV_STRIDE_AUTO);
    if (!buf) {
        free(pixels);
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
    free(pixels);
    return buf;
}
