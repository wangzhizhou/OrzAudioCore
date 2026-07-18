#include <gme/gme.h>
#include <stdlib.h>
#include <string.h>
#include "audio_engine.h"

// C++ 异常安全包装（在 cxx_helpers.cpp 中实现）
extern const char* safe_gme_open_data(const unsigned char*, int, Music_Emu**, int);
extern const char* safe_gme_start_track(Music_Emu*, int);
extern const char* safe_gme_track_info(Music_Emu*, gme_info_t**, int);
extern void        safe_gme_free_info(gme_info_t*);
extern const char* safe_gme_play(Music_Emu*, int, short*);
extern void        safe_gme_delete(Music_Emu*);

#define GME_SAMPLE_RATE 44100

typedef struct {
    Music_Emu *emu;
    short *render_buf;
    int render_buf_size;
    int duration_msec;
} GMEContext;

static void context_destroy(void *opaque);

static void *context_create(const char *format, const unsigned char *data, int len) {
    (void)format;
    GMEContext *ctx = (GMEContext *)calloc(1, sizeof(*ctx));
    if (!ctx) return NULL;

    const char* err = safe_gme_open_data(data, len, &ctx->emu, GME_SAMPLE_RATE);
    if (err) { context_destroy(ctx); return NULL; }

    // 从第一轨开始播放
    err = safe_gme_start_track(ctx->emu, 0);
    if (err) { context_destroy(ctx); return NULL; }

    gme_info_t *info = NULL;
    if (!safe_gme_track_info(ctx->emu, &info, 0) && info) {
        ctx->duration_msec = info->length > 0 ? info->length : info->play_length;
        safe_gme_free_info(info);
    }
    if (ctx->duration_msec <= 0) ctx->duration_msec = 150000;
    gme_set_fade(ctx->emu, ctx->duration_msec);

    return ctx;
}

static double context_get_duration(void *opaque) {
    GMEContext *ctx = (GMEContext *)opaque;
    // gme_set_fade() uses the library's standard 8-second fade window.
    return ctx && ctx->emu ? (ctx->duration_msec + 8000) / 1000.0 : 0;
}

static int context_get_sample_rate(void *opaque) { (void)opaque;
    return GME_SAMPLE_RATE;
}

static int context_get_channels(void *opaque) { (void)opaque;
    return 2; // gme 始终输出立体声
}

static int context_render(void *opaque, float *out, int frames) {
    GMEContext *ctx = (GMEContext *)opaque;
    if (!ctx || !ctx->emu) return 0;
    if (gme_track_ended(ctx->emu)) return 0;

    int sample_count = frames * 2; // 立体声
    if (!ctx->render_buf || sample_count > ctx->render_buf_size) {
        short *nb = (short *)realloc(ctx->render_buf, (size_t)sample_count * sizeof(short));
        if (!nb) return 0;
        ctx->render_buf = nb;
        ctx->render_buf_size = sample_count;
    }

    const char* err = safe_gme_play(ctx->emu, sample_count, ctx->render_buf);
    if (err) return 0;

    // int16 → float32 转换
    for (int i = 0; i < frames * 2; i++) {
        out[i] = ctx->render_buf[i] / 32768.0f;
    }
    return frames;
}

static void context_destroy(void *opaque) {
    GMEContext *ctx = (GMEContext *)opaque;
    if (!ctx) return;
    if (ctx->emu) safe_gme_delete(ctx->emu);
    free(ctx->render_buf);
    free(ctx);
}

// Legacy ABI adapter. New native/WASM callers use context_create directly.
static GMEContext *legacy;
static int impl_load(const unsigned char *data, int len) { context_destroy(legacy); legacy = context_create(NULL, data, len); return legacy != NULL; }
static double impl_get_duration(void) { return context_get_duration(legacy); }
static int impl_get_sample_rate(void) { return context_get_sample_rate(legacy); }
static int impl_get_channels(void) { return context_get_channels(legacy); }
static int impl_render(float *out, int frames) { return context_render(legacy, out, frames); }
static void impl_destroy(void) { context_destroy(legacy); legacy = NULL; }

// ── 导出 Decoder 实例 ──
const Decoder decoder_gme = {
    "game-music-emu",
    impl_load,
    impl_get_duration,
    impl_get_sample_rate,
    impl_get_channels,
    impl_render,
    impl_destroy,
    context_create, context_get_duration, context_get_sample_rate,
    context_get_channels, context_render, context_destroy
};
