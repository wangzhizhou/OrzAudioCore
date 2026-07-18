#include <asap.h>
#include <stdlib.h>
#include <string.h>
#include "audio_engine.h"

#define ASAP_SAMPLE_RATE 44100

typedef struct {
    ASAP *asap;
    short *render_buf;
    int render_buf_size;
    int total_duration_ms;
    int source_channels;
} ASAPContext;

static void context_destroy(void *opaque);

static void *context_create(const char *format, const unsigned char *data, int len) {
    (void)format;
    ASAPContext *ctx = (ASAPContext *)calloc(1, sizeof(*ctx));
    if (!ctx) return NULL;
    ctx->source_channels = 2;
    ctx->asap = ASAP_New();
    if (!ctx->asap) { context_destroy(ctx); return NULL; }

    ASAP_SetSampleRate(ctx->asap, ASAP_SAMPLE_RATE);
    ASAP_DetectSilence(ctx->asap, 5); // 5秒静音自动停止

    // ASAP_Load 参数: (self, filename, module, moduleLen)
    if (!ASAP_Load(ctx->asap, "song.sap", (const unsigned char*)data, len)) {
        context_destroy(ctx); return NULL;
    }

    // 获取时长
    const ASAPInfo *info = ASAP_GetInfo(ctx->asap);
    if (info) {
        ctx->total_duration_ms = ASAPInfo_GetDuration(info, 0);
        ctx->source_channels = ASAPInfo_GetChannels(info);
    }
    if (ctx->source_channels != 1 && ctx->source_channels != 2) ctx->source_channels = 2;
    if (ctx->total_duration_ms <= 0) ctx->total_duration_ms = 120000;

    // 开始播放
    if (!ASAP_PlaySong(ctx->asap, 0, ctx->total_duration_ms)) {
        context_destroy(ctx); return NULL;
    }

    return ctx;
}

static double context_get_duration(void *opaque) {
    ASAPContext *ctx = (ASAPContext *)opaque;
    return ctx && ctx->asap ? ctx->total_duration_ms / 1000.0 : 0;
}

static int context_get_sample_rate(void *opaque) { (void)opaque;
    return ASAP_SAMPLE_RATE;
}

static int context_get_channels(void *opaque) { (void)opaque;
    return 2; // ASAP 默认输出立体声（POKEY 双声道）
}

static int context_render(void *opaque, float *out, int frames) {
    ASAPContext *ctx = (ASAPContext *)opaque;
    if (!ctx || !ctx->asap) return 0;

    int byte_count = frames * ctx->source_channels * sizeof(short);
    if (!ctx->render_buf || byte_count > ctx->render_buf_size) {
        short *nb = (short *)realloc(ctx->render_buf, (size_t)byte_count);
        if (!nb) return 0;
        ctx->render_buf = nb;
        ctx->render_buf_size = byte_count;
    }

    int generated = ASAP_Generate(ctx->asap, (unsigned char*)ctx->render_buf, byte_count,
                                   ASAPSampleFormat_S16_L_E);
    int samples = generated / sizeof(short);
    int rendered_frames = samples / ctx->source_channels;

    if (ctx->source_channels == 1) {
        for (int i = 0; i < rendered_frames; i++) {
            float sample = ctx->render_buf[i] / 32768.0f;
            out[i * 2] = sample;
            out[i * 2 + 1] = sample;
        }
    } else {
        for (int i = 0; i < rendered_frames * 2; i++) {
            out[i] = ctx->render_buf[i] / 32768.0f;
        }
    }
    return rendered_frames;
}

static void context_destroy(void *opaque) {
    ASAPContext *ctx = (ASAPContext *)opaque;
    if (!ctx) return;
    if (ctx->asap) ASAP_Delete(ctx->asap);
    free(ctx->render_buf);
    free(ctx);
}

static ASAPContext *legacy;
static int impl_load(const unsigned char *data, int len) { context_destroy(legacy); legacy = context_create(NULL, data, len); return legacy != NULL; }
static double impl_get_duration(void) { return context_get_duration(legacy); }
static int impl_get_sample_rate(void) { return context_get_sample_rate(legacy); }
static int impl_get_channels(void) { return context_get_channels(legacy); }
static int impl_render(float *out, int frames) { return context_render(legacy, out, frames); }
static void impl_destroy(void) { context_destroy(legacy); legacy = NULL; }

// ── 导出 Decoder 实例 ──
const Decoder decoder_asap = {
    "asap",
    impl_load,
    impl_get_duration,
    impl_get_sample_rate,
    impl_get_channels,
    impl_render,
    impl_destroy,
    context_create, context_get_duration, context_get_sample_rate,
    context_get_channels, context_render, context_destroy
};
