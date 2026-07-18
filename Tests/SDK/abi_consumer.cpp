#include <cassert>
#include <string_view>
#include "orz_audio_core.h"

int main() {
    static_assert(ORZ_ABI_VERSION_MAJOR == 1u);
    assert(std::string_view(orz_status_message(ORZ_OK)) == "success");
    orz_stream_info info{};
    info.struct_size = sizeof(info);
    info.abi_version = ORZ_ABI_VERSION;
    assert(orz_decoder_get_stream_info(nullptr, &info) == ORZ_ERROR_INVALID_ARGUMENT);
    return 0;
}
