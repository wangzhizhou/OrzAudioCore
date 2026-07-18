#include <orz_audio_core.h>
int main(void) { return (orz_abi_version() >> 16u) == 1u ? 0 : 1; }
