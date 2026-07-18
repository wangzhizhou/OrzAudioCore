/**
 * sc68 decoder wrapper — Atari ST (YM) / Amiga formats
 *
 * Uses api68 API with inline replay data.
 * Output: 44100Hz stereo interleaved float32 PCM.
 */
#include <stdlib.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <stdatomic.h>
#include "audio_engine.h"
#ifndef EMSCRIPTEN
#define EMSCRIPTEN 1  // 暴露 api68_override_max_playtime 等 EMSCRIPTEN 专用函数
#endif
#include "api68/api68.h"

// ── 每个公开 handle 的物化 PCM 状态 ──
typedef struct {
    api68_t *sc68;
    int sample_rate;
    int duration_ms;
    int sc68_ended;
    int rendered_frames;
    int max_render_frames;
    int *decoded_pcm;
} SC68Context;

// libsc68/emu68 is internally singleton-based. Materialize its bounded
// three-second output while holding the core, then release it. Live decoder
// handles are fully independent and render concurrently from their own PCM.
static atomic_flag sc68_core_lock = ATOMIC_FLAG_INIT;
static void lock_core(void) { while (atomic_flag_test_and_set_explicit(&sc68_core_lock, memory_order_acquire)) {} }
static void unlock_core(void) { atomic_flag_clear_explicit(&sc68_core_lock, memory_order_release); }

// 适配 Emscripten 的 malloc 签名 (void*(unsigned long) vs void*(unsigned int))
static void *sc68_alloc(unsigned int size) { return malloc((size_t)size); }
static void sc68_free(void *p) { free(p); }

// ── inline replay data 注册 ──
extern void register_players(void);

// ── Decoder 接口实现 ──

static void context_destroy(void *opaque);

static void *context_create(const char *format, const unsigned char *data, int len)
{
    (void)format;
    SC68Context *ctx = (SC68Context *)calloc(1, sizeof(*ctx));
    if (!ctx) return NULL;
    ctx->sample_rate = 44100;
    lock_core();

    // 注册 inline replay modules
    register_players();

    // 初始化 API
    api68_init_t init68;
    memset(&init68, 0, sizeof(init68));
    init68.alloc = sc68_alloc;
    init68.free = sc68_free;
    init68.sampling_rate = ctx->sample_rate;

    ctx->sc68 = api68_init(&init68);
    if (!ctx->sc68) { unlock_core(); free(ctx); return NULL; }

    // 验证并加载（仅 sc68 原生格式）
    if (api68_verify_mem((const void*)data, len) < 0
        || api68_load_mem(ctx->sc68, (const void*)data, len)) {
        api68_shutdown(ctx->sc68); ctx->sc68 = NULL;
        unlock_core(); free(ctx); return NULL;
    }

    // Start once so libsc68 associates the replay before music_info().
    api68_play(ctx->sc68, 0);

    // 获取时长
    api68_music_info_t info;
    for (int try_track = 0; try_track >= -1 && ctx->duration_ms <= 0; try_track--) {
        memset(&info, 0, sizeof(info));
        int ret = api68_music_info(ctx->sc68, &info, try_track, 0);
        if (ret == 0 && info.time_ms > 0 && info.time_ms < 3600000) {
            ctx->duration_ms = info.time_ms;
        }
    }
    // Unknown/implausible metadata gets the same explicit three-minute policy
    // as SID. Materialization is required because this libsc68 generation has
    // process-global emu68 state and cannot keep two live cores.
    if (ctx->duration_ms <= 0 || ctx->duration_ms > 180000) ctx->duration_ms = 180000;
    api68_override_max_playtime(ctx->duration_ms);

    // 计算最大渲染帧数（用于 impl_render 中的硬限制）
    ctx->max_render_frames = (int)((int64_t)ctx->duration_ms * ctx->sample_rate / 1000);

    ctx->decoded_pcm = (int *)malloc((size_t)ctx->max_render_frames * sizeof(int));
    if (!ctx->decoded_pcm) {
        api68_shutdown(ctx->sc68); ctx->sc68 = NULL; unlock_core(); free(ctx); return NULL;
    }
    int decoded = 0;
    while (decoded < ctx->max_render_frames) {
        int count = ctx->max_render_frames - decoded;
        if (count > 512) count = 512;
        int status = api68_process(ctx->sc68, ctx->decoded_pcm + decoded, count);
        if (status == API68_MIX_ERROR) break;
        decoded += count;
        if (status & API68_END) break;
    }
    api68_stop(ctx->sc68);
    api68_shutdown(ctx->sc68);
    ctx->sc68 = NULL;
    unlock_core();
    ctx->max_render_frames = decoded;
    if (decoded <= 0) { free(ctx->decoded_pcm); free(ctx); return NULL; }

    return ctx;
}

static double context_get_duration(void *opaque)
{
    SC68Context *ctx = (SC68Context *)opaque;
    return ctx ? ctx->duration_ms / 1000.0 : 0;
}

static int context_get_sample_rate(void *opaque)
{
    return opaque ? ((SC68Context *)opaque)->sample_rate : 0;
}

static int context_get_channels(void *opaque)
{
    return opaque ? 2 : 0;
}

static int context_render(void *opaque, float *out, int frames)
{
    SC68Context *ctx = (SC68Context *)opaque;
    if (!ctx || !ctx->decoded_pcm) return 0;

    // 歌曲已结束，返回 0 让 JS 流式循环退出
    if (ctx->sc68_ended) return 0;

    int to_process = frames;

    // 硬限制：最多渲染 duration_ms 对应的帧数
    // 防止 api68 内部 m->frames 覆盖了 max_playtime 设置
    if (ctx->max_render_frames > 0 && ctx->rendered_frames >= ctx->max_render_frames) {
        ctx->sc68_ended = 1;
        return 0;
    }
    int remaining = ctx->max_render_frames > 0
        ? ctx->max_render_frames - ctx->rendered_frames
        : to_process;
    if (to_process > remaining) to_process = remaining;

    for (int i = 0; i < to_process; i++) {
        int v = ctx->decoded_pcm[ctx->rendered_frames + i];
        out[i * 2 + 0] = (float)(int16_t)(v & 0xFFFF) / 32768.0f;
        out[i * 2 + 1] = (float)(int16_t)(v >> 16) / 32768.0f;
    }
    ctx->rendered_frames += to_process;
    return to_process;
}

static void context_destroy(void *opaque)
{
    SC68Context *ctx = (SC68Context *)opaque;
    if (!ctx) return;
    if (ctx->sc68) {
        api68_stop(ctx->sc68);
        api68_shutdown(ctx->sc68);
    }
    free(ctx->decoded_pcm);
    free(ctx);
}

static SC68Context *legacy;
static int impl_load(const unsigned char *data, int len) { context_destroy(legacy); legacy = context_create(NULL, data, len); return legacy != NULL; }
static double impl_get_duration(void) { return context_get_duration(legacy); }
static int impl_get_sample_rate(void) { return context_get_sample_rate(legacy); }
static int impl_get_channels(void) { return context_get_channels(legacy); }
static int impl_render(float *out, int frames) { return context_render(legacy, out, frames); }
static void impl_destroy(void) { context_destroy(legacy); legacy = NULL; }

// ── 导出 Decoder 实例 ──
const Decoder decoder_sc68 = {
    "sc68",
    impl_load,
    impl_get_duration,
    impl_get_sample_rate,
    impl_get_channels,
    impl_render,
    impl_destroy,
    context_create, context_get_duration, context_get_sample_rate,
    context_get_channels, context_render, context_destroy
};
