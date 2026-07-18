/**
 * v2m_native_impl.cpp — V2M 原生解码器
 *
 * 使用 jgilje/v2m-player 库的 V2MPlayer API。
 * 注意：V2MPlayer::Open() 要求数据指针在 player 生命周期内保持有效。
 * 因此 impl_load 必须复制输入数据到自有缓冲区。
 */
#include <stdlib.h>
#include <string.h>
#include <new>
#include <mutex>
#include "audio_engine.h"
#include "v2mplayer.h"

// v2mplayer's reference CLI converts every historical V2M revision to the
// newest synth parameter layout before Open(). Opening older files directly
// often succeeds but maps their patches incorrectly and produces silence.
extern void sdInit();
extern void ConvertV2M(const unsigned char *input, int input_len,
                       unsigned char **output, int *output_len);

static std::once_flag v2m_sounddef_once;

// ── 合成器状态 ──

struct V2MContext {
    V2MPlayer *player = NULL;
    unsigned char *owned_data = NULL;
    int sample_rate = 44100;
    int v2m_ended = 0;
    uint64_t rendered_frames = 0;
    uint64_t duration_frames = 0;
};

// ── Decoder 接口 ──

static void context_destroy(void *opaque);

static void *context_create(const char *format, const unsigned char *data, int len) {
    (void)format;
    if (!data || len <= 0) return NULL;
    V2MContext *ctx = new(std::nothrow) V2MContext();
    if (!ctx) return NULL;

    std::call_once(v2m_sounddef_once, [] { sdInit(); });
    unsigned char *converted = NULL;
    int converted_len = 0;
    ConvertV2M(data, len, &converted, &converted_len);
    if (!converted || converted_len <= 0) { delete[] converted; delete ctx; return NULL; }

    // V2MPlayer::Open requires the converted data for the player lifetime.
    ctx->owned_data = (unsigned char *)malloc((size_t)converted_len);
    if (!ctx->owned_data) { delete[] converted; delete ctx; return NULL; }
    memcpy(ctx->owned_data, converted, (size_t)converted_len);
    delete[] converted;

    ctx->player = new(std::nothrow) V2MPlayer();
    if (!ctx->player) { context_destroy(ctx); return NULL; }
    ctx->player->Init(1000);

    // Open 加载 .v2m 数据（使用拷贝后的数据）
    if (!ctx->player->Open(ctx->owned_data, ctx->sample_rate, false)) {
        context_destroy(ctx); return NULL;
    }

    // Play 调用启动回放（必须在 load 时调用一次，不要在 render 重复调用，
    // 因为 V2MPlayer::Play() 内部会 Stop() + Reset()，重复调用会丢失进度）
    ctx->player->Play(0);
    // Length() is expressed in seconds even though Play() accepts milliseconds.
    // Treating it as milliseconds truncated tunes to 1/1000 of their duration.
    ctx->duration_frames = (uint64_t)ctx->player->Length() * ctx->sample_rate;

    return ctx;
}

static double context_get_duration(void *opaque) {
    V2MContext *ctx = (V2MContext *)opaque;
    return ctx && ctx->player ? (double)ctx->player->Length() : 0;
}

static int context_get_sample_rate(void *opaque) { return opaque ? ((V2MContext *)opaque)->sample_rate : 0; }
static int context_get_channels(void *opaque) { return opaque ? 2 : 0; }

static int context_render(void *opaque, float *out, int frames) {
    V2MContext *ctx = (V2MContext *)opaque;
    if (!ctx || !ctx->player || !out || frames <= 0) return 0;

    // 歌曲已结束（上次检测到 IsPlaying=false），返回 0 让 JS 流式循环退出
    if (ctx->v2m_ended) return 0;
    if (ctx->rendered_frames >= ctx->duration_frames) { ctx->v2m_ended = 1; return 0; }
    if ((uint64_t)frames > ctx->duration_frames - ctx->rendered_frames) {
        frames = (int)(ctx->duration_frames - ctx->rendered_frames);
    }

    // V2MPlayer::Render 输出 float32 stereo interleaved
    ctx->player->Render(out, frames, false);

    // 检测歌曲是否结束：Render 后检查 IsPlaying，若结束则标记并在下次返回 0
    if (!ctx->player->IsPlaying()) {
        ctx->v2m_ended = 1;
    }
    ctx->rendered_frames += (uint64_t)frames;

    // 音量衰减
    for (int i = 0; i < frames * 2; i++) {
        out[i] *= 0.3f;
    }

    return frames;
}

static void context_destroy(void *opaque) {
    V2MContext *ctx = (V2MContext *)opaque;
    if (!ctx) return;
    if (ctx->player) {
        ctx->player->Close();
        delete ctx->player;
    }
    free(ctx->owned_data);
    delete ctx;
}

static V2MContext *legacy;
static int impl_load(const unsigned char *data, int len) { context_destroy(legacy); legacy = (V2MContext *)context_create(NULL, data, len); return legacy != NULL; }
static double impl_get_duration(void) { return context_get_duration(legacy); }
static int impl_get_sample_rate(void) { return context_get_sample_rate(legacy); }
static int impl_get_channels(void) { return context_get_channels(legacy); }
static int impl_render(float *out, int frames) { return context_render(legacy, out, frames); }
static void impl_destroy(void) { context_destroy(legacy); legacy = NULL; }

// ── 导出 Decoder 实例（必须 extern "C" 以覆盖 stub_decoders.c 的弱符号）──

extern "C"
const Decoder decoder_v2m = {
    "v2m-player-native",
    impl_load,
    impl_get_duration,
    impl_get_sample_rate,
    impl_get_channels,
    impl_render,
    impl_destroy,
    context_create, context_get_duration, context_get_sample_rate,
    context_get_channels, context_render, context_destroy
};
