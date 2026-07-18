#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <new>

#include <sidplayfp/sidplayfp.h>
#include <sidplayfp/SidTune.h>
#include <sidplayfp/SidConfig.h>
#include <sidplayfp/SidTuneInfo.h>
#include <sidplayfp/sidbuilder.h>
#include <sidplayfp/siddefs.h>

// sidlite 模拟器（内建于 libsidplayfp）
#include <sidlite.h>

extern "C" {
#include "audio_engine.h"
}

// ── 旧 ABI 兼容状态；实例 API 不使用它 ──
static const unsigned int SAMPLE_RATE = 44100;

struct SIDContext {
    sidplayfp *player = nullptr;
    SidTune *tune = nullptr;
    sidbuilder *sid_builder = nullptr;
    short *mix_buf = nullptr;
    unsigned int mix_buf_size = 0;
    unsigned int pending_offset = 0;
    unsigned int pending_frames = 0;
    double song_length_ms = 0;
    unsigned long long cycle_remainder = 0;
    unsigned long long rendered_frames = 0;
    unsigned int sid_clock_hz = 985248;
};

static void context_destroy(void *opaque);

// ── Decoder 接口实现 ──

static void *context_create(const char *format, const unsigned char *data, int len) {
    (void)format;
    SIDContext *ctx = new(std::nothrow) SIDContext();
    if (!ctx) return nullptr;
    try {
    // 从内存加载 SID 文件
    ctx->tune = new(std::nothrow) SidTune(data, (uint_least32_t)len);
    if (!ctx->tune) { context_destroy(ctx); return nullptr; }

    if (!ctx->tune->getStatus()) {
        context_destroy(ctx); return nullptr;
    }

    // 创建 sidlite 模拟器
    ctx->sid_builder = new(std::nothrow) SIDLiteBuilder("sidlite");
    if (!ctx->sid_builder) { context_destroy(ctx); return nullptr; }

    // 创建播放器
    ctx->player = new(std::nothrow) sidplayfp();
    if (!ctx->player) { context_destroy(ctx); return nullptr; }

    // 配置：44100Hz + sidlite 模拟器
    SidConfig cfg;
    cfg.frequency = SAMPLE_RATE;
    cfg.sidEmulation = ctx->sid_builder;
    if (!ctx->player->config(cfg)) { context_destroy(ctx); return nullptr; }

    // 加载曲目（内部调用 config，重置引擎状态）
    if (!ctx->player->load(ctx->tune)) { context_destroy(ctx); return nullptr; }

    // 重置引擎，再初始化混音器（立体声）
    // initMixer 需要在 reset() 之后调用，否则混音器状态被清除
    ctx->player->initMixer(true);
    ctx->player->reset();

    const SidTuneInfo *tune_info = ctx->tune->getInfo();
    if (tune_info && tune_info->clockSpeed() == SidTuneInfo::CLOCK_NTSC) {
        ctx->sid_clock_hz = 1022727;
    }
    // PSID/RSID files do not carry a duration. Keep a documented playback
    // policy limit until a Songlengths.md5-compatible database is available.
    ctx->song_length_ms = 180000.0;

    return ctx;
    } catch (...) { context_destroy(ctx); return nullptr; }
}

static double context_get_duration(void *opaque) {
    SIDContext *ctx = (SIDContext *)opaque;
    return ctx ? ctx->song_length_ms / 1000.0 : 0;
}

static int context_get_sample_rate(void *opaque) { (void)opaque;
    return SAMPLE_RATE;
}

static int context_get_channels(void *opaque) { (void)opaque;
    return 2; // 立体声
}

static int context_render(void *opaque, float *out, int frames) {
    SIDContext *ctx = (SIDContext *)opaque;
    if (!ctx || !ctx->player) return 0;
    unsigned long long limit_frames = (unsigned long long)(ctx->song_length_ms * SAMPLE_RATE / 1000.0);
    if (ctx->rendered_frames >= limit_frames) return 0;
    if ((unsigned long long)frames > limit_frames - ctx->rendered_frames) {
        frames = (int)(limit_frames - ctx->rendered_frames);
    }

    try {
    // Use an internal fixed-size generation quantum. The number of samples
    // produced by sidplayfp::play(cycles) is not exactly proportional for
    // every individual call, so tying cycles to the caller's block size makes
    // the stream lose a few frames on every small render request.
    const unsigned int GENERATION_FRAMES = 4096;
    unsigned int total_rendered = 0;
    while (total_rendered < (unsigned int)frames) {
        if (ctx->pending_offset >= ctx->pending_frames) {
            unsigned long long numerator =
                (unsigned long long)GENERATION_FRAMES * ctx->sid_clock_hz + ctx->cycle_remainder;
            unsigned long long cycles_64 = numerator / SAMPLE_RATE;
            ctx->cycle_remainder = numerator % SAMPLE_RATE;
            if (cycles_64 < 1) cycles_64 = 1;

            int per_channel = ctx->player->play((unsigned int)cycles_64);
            if (per_channel <= 0) break;
            unsigned int needed = (unsigned int)per_channel;
            if (needed > ctx->mix_buf_size) {
                short *nb = (short *)realloc(ctx->mix_buf, (size_t)needed * 2 * sizeof(short));
                if (!nb) return (int)total_rendered;
                ctx->mix_buf = nb;
                ctx->mix_buf_size = needed;
            }
            unsigned int mixed = ctx->player->mix(ctx->mix_buf, needed);
            ctx->pending_offset = 0;
            ctx->pending_frames = mixed / 2;
            if (ctx->pending_frames == 0) break;
        }

        unsigned int available = ctx->pending_frames - ctx->pending_offset;
        unsigned int wanted = (unsigned int)frames - total_rendered;
        unsigned int take = available < wanted ? available : wanted;
        for (unsigned int i = 0; i < take * 2; i++) {
            out[total_rendered * 2 + i] = ctx->mix_buf[ctx->pending_offset * 2 + i] / 32768.0f;
        }
        ctx->pending_offset += take;
        total_rendered += take;
    }

    ctx->rendered_frames += total_rendered;
    return (int)total_rendered;
    } catch (...) { return 0; }
}

static void context_destroy(void *opaque) {
    SIDContext *ctx = (SIDContext *)opaque;
    if (!ctx) return;
    delete ctx->player;
    delete ctx->tune;
    delete ctx->sid_builder;
    free(ctx->mix_buf);
    delete ctx;
}

static SIDContext *legacy;
static int impl_load(const unsigned char *data, int len) { context_destroy(legacy); legacy = (SIDContext *)context_create(nullptr, data, len); return legacy != nullptr; }
static double impl_get_duration() { return context_get_duration(legacy); }
static int impl_get_sample_rate() { return context_get_sample_rate(legacy); }
static int impl_get_channels() { return context_get_channels(legacy); }
static int impl_render(float *out, int frames) { return context_render(legacy, out, frames); }
static void impl_destroy() { context_destroy(legacy); legacy = nullptr; }

// ── 导出 Decoder 实例（C 链接）──
extern "C" const Decoder decoder_sidplayfp = {
    "libsidplayfp",
    impl_load,
    impl_get_duration,
    impl_get_sample_rate,
    impl_get_channels,
    impl_render,
    impl_destroy,
    context_create, context_get_duration, context_get_sample_rate,
    context_get_channels, context_render, context_destroy
};
