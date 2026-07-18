#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <string.h>
#include "orz_audio_core.h"

static const uint8_t midi_fixture[] = {
    'M','T','h','d', 0,0,0,6, 0,0, 0,1, 0,96,
    'M','T','r','k', 0,0,0,15,
    0,0xC0,0,
    0,0x90,60,100,
    96,0x80,60,0,
    0,0xFF,0x2F,0
};

int main(void) {
    enum { instance_count = 12, frames = 512 };
    OrzDecoderHandle *decoders[instance_count] = {0};
    float reference[frames * 2] = {0};
    float actual[frames * 2] = {0};
    uint32_t rendered = 0;

    for (int i = 0; i < instance_count; ++i) {
        assert(orz_decoder_create_memory(midi_fixture, sizeof(midi_fixture), "mid", NULL,
                                         &decoders[i]) == ORZ_OK);
    }
    assert(orz_decoder_render_f32(decoders[0], reference, frames, &rendered) == ORZ_OK);
    assert(rendered == frames);
    for (int i = 1; i < instance_count; ++i) {
        uint32_t actual_frames = 0;
        memset(actual, 0, sizeof(actual));
        assert(orz_decoder_render_f32(decoders[i], actual, frames, &actual_frames) == ORZ_OK);
        assert(actual_frames == rendered);
        assert(memcmp(reference, actual, sizeof(reference)) == 0);
    }
    for (int i = 0; i < instance_count; ++i) orz_decoder_destroy_v1(decoders[i]);
    return 0;
}
