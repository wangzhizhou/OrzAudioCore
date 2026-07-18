/**
 * adplug_wrap.cpp — AdPlug OPL2/3 decoder C++ wrapper for WASM
 *
 * Formats: rad, d00, hsc (+ 20+ more OPL2/3 formats)
 * Uses: CEmuopl (emulated OPL2), CAdPlug factory pattern
 * File access: Write to MEMFS, then load via CProvider_Filesystem
 */
#include <stdlib.h>
#include <string.h>
#include <string>
#include <vector>
#include <atomic>

#include <adplug.h>
#include <emuopl.h>

// Forward declarations (defined in adplug_impl.c)
extern "C" void adplug_destroy();
extern "C" int adplug_load(const unsigned char *data, int len);
extern "C" double adplug_get_duration();
extern "C" int adplug_get_sample_rate();
extern "C" int adplug_get_channels();
extern "C" int adplug_render(float *out, int frames);
extern "C" {
#include "audio_engine.h"
}

// 由 orz_dispatch.c 设置的当前格式名（如 "hsc", "amd", "rad"）
extern const char *orz_current_format;

// ── State ──
struct AdPlugContext {
    CEmuopl *opl = NULL;
    CPlayer *player = NULL;
    int sample_rate = 44100;
    double song_duration = 0;
    int samples_remaining_in_tick = 0;
    double fractional_tick_samples = 0.0;
    bool playback_ended = false;
};

// Temporary filename for MEMFS
// 扩展名根据 orz_current_format 设置（"hsc"→".hsc" 等），使 AdPlug factory
// 的扩展名匹配机制正确识别格式。程序化编译为 ".adplug" 走全 player 遍历。
static std::atomic<unsigned int> tmp_counter{0};

extern "C" void adplug_context_destroy(void *opaque);
extern "C" void *adplug_context_create(const char *format, const unsigned char *data, int len)
{
    if (!data || len <= 0) return NULL;
    AdPlugContext *ctx = new(std::nothrow) AdPlugContext();
    if (!ctx) return NULL;

    // 根据当前格式名确定 MEMFS 文件的扩展名
    const char *ext = ".adplug";
    if (format) {
        if (strcmp(format, "hsc") == 0) ext = ".hsc";
        else if (strcmp(format, "amd") == 0) ext = ".amd";
        else if (strcmp(format, "rad") == 0) ext = ".rad";
        else if (strcmp(format, "d00") == 0) ext = ".d00";
        else if (strcmp(format, "hsp") == 0) ext = ".hsp";
    }

    // Write data to MEMFS with format-appropriate extension
    char tmp_file_path[96];
    snprintf(tmp_file_path, sizeof(tmp_file_path), "/tmp/adplug_%u%s", tmp_counter.fetch_add(1) + 1, ext);
    FILE *f = fopen(tmp_file_path, "wb");
    if (!f) { delete ctx; return NULL; }
    if (fwrite(data, 1, (size_t)len, f) != (size_t)len) { fclose(f); remove(tmp_file_path); delete ctx; return NULL; }
    fclose(f);

    // Create OPL emulator: 44100Hz, 16-bit, stereo
    ctx->opl = new(std::nothrow) CEmuopl(ctx->sample_rate, true, true);
    if (!ctx->opl) { remove(tmp_file_path); delete ctx; return NULL; }
    ctx->opl->init();

    // Load file with AdPlug factory（通过内容检测格式，不依赖扩展名）
    ctx->player = CAdPlug::factory(tmp_file_path, ctx->opl);
    remove(tmp_file_path);
    if (!ctx->player) {
        adplug_context_destroy(ctx); return NULL;
    }

    // Get duration
    ctx->song_duration = ctx->player->songlength() / 1000.0;
    if (ctx->song_duration <= 0) ctx->song_duration = 120.0;

    // MEMFS 是临时的，不需要显式删除
    // 注意：在 ALLOW_MEMORY_GROWTH=1 时调用 remove() 可能导致 TextDecoder 异常
    return ctx;
}

extern "C" double adplug_context_get_duration(void *opaque) { return opaque ? ((AdPlugContext *)opaque)->song_duration : 0; }
extern "C" int adplug_context_get_sample_rate(void *opaque) { return opaque ? ((AdPlugContext *)opaque)->sample_rate : 0; }
extern "C" int adplug_context_get_channels(void *opaque) { return opaque ? 2 : 0; }

extern "C" int adplug_context_render(void *opaque, float *out, int frames)
{
    AdPlugContext *ctx = (AdPlugContext *)opaque;
    if (!ctx || !ctx->player || !ctx->opl || ctx->playback_ended) return 0;

    // AdPlug render loop:
    // player->update() = advance one tick, writes OPL registers
    // emuopl->update(buf, samples) = render OPL output to buffer
    //
    int total = 0;
    while (total < frames) {
        if (ctx->samples_remaining_in_tick <= 0) {
            if (!ctx->player->update()) {
                ctx->playback_ended = true;
                break;
            }

            float refresh = ctx->player->getrefresh();
            if (refresh <= 0.0f) refresh = 50.0f;
            double exact_samples =
                (double)ctx->sample_rate / refresh + ctx->fractional_tick_samples;
            ctx->samples_remaining_in_tick = (int)exact_samples;
            ctx->fractional_tick_samples = exact_samples - ctx->samples_remaining_in_tick;
            if (ctx->samples_remaining_in_tick < 1) ctx->samples_remaining_in_tick = 1;
        }

        int chunk = frames - total;
        if (chunk > ctx->samples_remaining_in_tick) {
            chunk = ctx->samples_remaining_in_tick;
        }

        // Render OPL audio directly to output
        short mixbuf[8192];
        int mix_samples = (chunk > 4096) ? 4096 : chunk;

        ctx->opl->update(mixbuf, mix_samples);

        // short → float
        for (int i = 0; i < mix_samples * 2; i++) {
            out[total * 2 + i] = mixbuf[i] / 32768.0f;
        }
        total += mix_samples;
        ctx->samples_remaining_in_tick -= mix_samples;
    }

    return total;
}

extern "C" void adplug_context_destroy(void *opaque)
{
    AdPlugContext *ctx = (AdPlugContext *)opaque;
    if (!ctx) return;
    delete ctx->player;
    delete ctx->opl;
    delete ctx;
}

static AdPlugContext *legacy;
extern "C" int adplug_load(const unsigned char *data, int len) { adplug_context_destroy(legacy); legacy = (AdPlugContext *)adplug_context_create(orz_current_format, data, len); return legacy != NULL; }
extern "C" double adplug_get_duration() { return adplug_context_get_duration(legacy); }
extern "C" int adplug_get_sample_rate() { return adplug_context_get_sample_rate(legacy); }
extern "C" int adplug_get_channels() { return adplug_context_get_channels(legacy); }
extern "C" int adplug_render(float *out, int frames) { return adplug_context_render(legacy, out, frames); }
extern "C" void adplug_destroy() { adplug_context_destroy(legacy); legacy = NULL; }
