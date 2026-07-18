#include <assert.h>
#include <string.h>
#include "orz_audio_core.h"

int main(void) {
    assert((orz_abi_version() >> 16u) == 1u);
    assert(strstr(orz_build_info(), "OrzAudioCore") != NULL);
    assert(strcmp(orz_status_message(ORZ_ERROR_INVALID_ARGUMENT), "invalid argument") == 0);
    assert(orz_get_format_count() >= 3u);
    orz_format_info info = {0};
    info.struct_size = sizeof(info);
    info.abi_version = ORZ_ABI_VERSION;
    assert(orz_get_format_info(0, &info) == ORZ_OK);
    assert(info.format_id != NULL && info.decoder_id != NULL);
    assert(orz_get_format_info(orz_get_format_count(), &info) == ORZ_ERROR_INVALID_ARGUMENT);
    orz_format_info undersized = {0};
    undersized.struct_size = sizeof(uint32_t);
    undersized.abi_version = ORZ_ABI_VERSION;
    assert(orz_get_format_info(0, &undersized) == ORZ_ERROR_ABI_MISMATCH);
    orz_decoder_destroy_v1(NULL);
    return 0;
}
