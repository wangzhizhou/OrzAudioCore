/**
 * uade_native_ahx.c — AHX 原生解码器
 *
 * 使用 ahx2play 库（8bitbubsy C 移植版）直接解码 AHX 格式。
 */
#include <stdlib.h>
#include <string.h>
#include "audio_engine.h"
#include "replayer.h"

typedef struct {
    void *replayer_state;
    void *paula_state;
    int play_started;
    int initialized;
    int16_t *render_buf;
    int render_buf_size;
} AHXContext;

typedef struct { void *replayer; void *paula; } AHXPrevious;

static int save_previous(AHXPrevious *previous) {
    previous->replayer = malloc(ahxReplayerStateSize());
    previous->paula = malloc(ahxPaulaStateSize());
    if (!previous->replayer || !previous->paula) {
        free(previous->replayer); free(previous->paula); return 0;
    }
    ahxReplayerStateSave(previous->replayer);
    ahxPaulaStateSave(previous->paula);
    return 1;
}

static void restore_previous(AHXPrevious *previous) {
    ahxReplayerStateLoad(previous->replayer);
    ahxPaulaStateLoad(previous->paula);
    free(previous->replayer); free(previous->paula);
}

static void load_context(AHXContext *ctx) {
    ahxReplayerStateLoad(ctx->replayer_state);
    ahxPaulaStateLoad(ctx->paula_state);
}

static void save_context(AHXContext *ctx) {
    ahxReplayerStateSave(ctx->replayer_state);
    ahxPaulaStateSave(ctx->paula_state);
}

static void context_destroy(void *opaque);

static void *context_create(const char *format, const unsigned char *data, int len) {
    (void)format; (void)len;
    AHXContext *ctx = (AHXContext *)calloc(1, sizeof(*ctx));
    if (!ctx) return NULL;
    ctx->replayer_state = calloc(1, ahxReplayerStateSize());
    ctx->paula_state = calloc(1, ahxPaulaStateSize());
    if (!ctx->replayer_state || !ctx->paula_state) { context_destroy(ctx); return NULL; }

    AHXPrevious previous;
    if (!save_previous(&previous)) { context_destroy(ctx); return NULL; }
    load_context(ctx);
    if (!ahxInit(44100, 4096, 256, 20)) {
        restore_previous(&previous); context_destroy(ctx); return NULL;
    }
    ctx->initialized = 1;
    if (!ahxLoadFromRAM(data)) {
        ahxFree(); ahxClose(); ctx->initialized = 0;
        restore_previous(&previous); context_destroy(ctx); return NULL;
    }
    save_context(ctx);
    restore_previous(&previous);
    return ctx;
}

static double context_get_duration(void *opaque) { return opaque ? 120.0 : 0; }
static int context_get_sample_rate(void *opaque) { return opaque ? 44100 : 0; }
static int context_get_channels(void *opaque) { return opaque ? 2 : 0; }

static int context_render(void *opaque, float *out, int frames) {
    AHXContext *ctx = (AHXContext *)opaque;
    if (!ctx || !ctx->initialized || !out || frames <= 0) return 0;
    AHXPrevious previous;
    if (!save_previous(&previous)) return 0;
    load_context(ctx);
    if (!ctx->play_started) { ahxPlay(0); ctx->play_started = 1; }
    int needed = frames * 2;
    if (needed > ctx->render_buf_size) {
        int16_t *nb = (int16_t *)realloc(ctx->render_buf, (size_t)needed * sizeof(int16_t));
        if (!nb) { save_context(ctx); restore_previous(&previous); return 0; }
        ctx->render_buf = nb; ctx->render_buf_size = needed;
    }
    // paulaOutputSamples() advances the CIA clock and invokes tickReplayer()
    // at the exact sample boundary. Calling tickReplayer() here as well makes
    // playback speed depend on the caller's render block size.
    paulaOutputSamples(ctx->render_buf, frames);
    for (int i = 0; i < frames * 2; i++) out[i] = ctx->render_buf[i] / 32768.0f;
    save_context(ctx);
    restore_previous(&previous);
    return frames;
}

static void context_destroy(void *opaque) {
    AHXContext *ctx = (AHXContext *)opaque;
    if (!ctx) return;
    if (ctx->initialized && ctx->replayer_state && ctx->paula_state) {
        AHXPrevious previous;
        if (save_previous(&previous)) {
            load_context(ctx);
            ahxFree(); ahxClose();
            restore_previous(&previous);
        }
    }
    free(ctx->render_buf);
    free(ctx->replayer_state);
    free(ctx->paula_state);
    free(ctx);
}

static AHXContext *legacy;
static int impl_load(const unsigned char *data, int len) { context_destroy(legacy); legacy = context_create(NULL, data, len); return legacy != NULL; }
static double impl_get_duration(void) { return context_get_duration(legacy); }
static int impl_get_sample_rate(void) { return context_get_sample_rate(legacy); }
static int impl_get_channels(void) { return context_get_channels(legacy); }
static int impl_render(float *out, int frames) { return context_render(legacy, out, frames); }
static void impl_destroy(void) {
    context_destroy(legacy); legacy = NULL;
}

const Decoder decoder_uade_ahx = {
    "ahx2play", impl_load, impl_get_duration,
    impl_get_sample_rate, impl_get_channels,
    impl_render, impl_destroy,
    context_create, context_get_duration, context_get_sample_rate,
    context_get_channels, context_render, context_destroy
};
