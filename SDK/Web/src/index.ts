export const ORZ_ABI_VERSION = 0x0001_0000;
export const ORZ_OK = 0;
export const ORZ_END_OF_STREAM = 1;

export interface EmscriptenOrzModule {
  HEAPU8: Uint8Array;
  HEAPU32: Uint32Array;
  HEAPF64: Float64Array;
  HEAPF32: Float32Array;
  _malloc(size: number): number;
  _free(pointer: number): void;
  _orz_abi_version(): number;
  _orz_decoder_create_memory(data: number, size: number, format: number, config: number, output: number): number;
  _orz_decoder_get_stream_info(decoder: number, output: number): number;
  _orz_decoder_render_f32(decoder: number, output: number, frames: number, rendered: number): number;
  _orz_decoder_seek(decoder: number, milliseconds: number): number;
  _orz_decoder_select_subsong_v1(decoder: number, subsong: number): number;
  _orz_decoder_reset(decoder: number): number;
  _orz_decoder_cancel(decoder: number): number;
  _orz_decoder_destroy_v1(decoder: number): void;
  UTF8ToString(pointer: number): string;
  stringToUTF8(value: string, pointer: number, capacity: number): void;
  lengthBytesUTF8(value: string): number;
}

export interface StreamInfo { sampleRate: number; channels: number; duration: number; subsongCount: number; capabilities: number }

export class OrzAudioCoreError extends Error {
  constructor(public readonly status: number, operation: string) { super(`${operation} failed with OrzAudioCore status ${status}`); }
}

export class AudioDecoder {
  readonly info: StreamInfo;
  #handle: number;
  constructor(private readonly module: EmscriptenOrzModule, handle: number) {
    this.#handle = handle;
    const pointer = module._malloc(64);
    try {
      module.HEAPU8.fill(0, pointer, pointer + 64);
      module.HEAPU32[pointer >>> 2] = 64;
      module.HEAPU32[(pointer + 4) >>> 2] = ORZ_ABI_VERSION;
      check(module._orz_decoder_get_stream_info(handle, pointer), 'stream info');
      this.info = {
        sampleRate: module.HEAPU32[(pointer + 8) >>> 2], channels: module.HEAPU32[(pointer + 12) >>> 2],
        duration: module.HEAPF64[(pointer + 16) >>> 3], subsongCount: module.HEAPU32[(pointer + 24) >>> 2],
        capabilities: module.HEAPU32[(pointer + 28) >>> 2]
      };
    } finally { module._free(pointer); }
  }
  render(maxFrames: number): Float32Array {
    if (!this.#handle || maxFrames <= 0) throw new OrzAudioCoreError(-1, 'render');
    const bytes = maxFrames * this.info.channels * 4;
    const pcm = this.module._malloc(bytes), rendered = this.module._malloc(4);
    try {
      const status = this.module._orz_decoder_render_f32(this.#handle, pcm, maxFrames, rendered);
      if (status === ORZ_END_OF_STREAM) return new Float32Array();
      check(status, 'render');
      const count = this.module.HEAPU32[rendered >>> 2] * this.info.channels;
      return this.module.HEAPF32.slice(pcm >>> 2, (pcm >>> 2) + count);
    } finally { this.module._free(rendered); this.module._free(pcm); }
  }
  seek(milliseconds: number): void { check(this.module._orz_decoder_seek(this.#handle, milliseconds), 'seek'); }
  selectSubsong(index: number): void { check(this.module._orz_decoder_select_subsong_v1(this.#handle, index), 'select subsong'); }
  reset(): void { check(this.module._orz_decoder_reset(this.#handle), 'reset'); }
  cancel(): void { if (this.#handle) this.module._orz_decoder_cancel(this.#handle); }
  close(): void { if (this.#handle) { this.module._orz_decoder_destroy_v1(this.#handle); this.#handle = 0; } }
}

export function createDecoder(module: EmscriptenOrzModule, data: Uint8Array, format: string): AudioDecoder {
  if (module._orz_abi_version() !== ORZ_ABI_VERSION) throw new OrzAudioCoreError(-8, 'ABI negotiation');
  const dataPointer = module._malloc(data.length), length = module.lengthBytesUTF8(format) + 1;
  const formatPointer = module._malloc(length), outputPointer = module._malloc(4);
  try {
    module.HEAPU8.set(data, dataPointer); module.stringToUTF8(format, formatPointer, length);
    module.HEAPU32[outputPointer >>> 2] = 0;
    check(module._orz_decoder_create_memory(dataPointer, data.length, formatPointer, 0, outputPointer), 'create');
    const handle = module.HEAPU32[outputPointer >>> 2];
    try { return new AudioDecoder(module, handle); }
    catch (error) { module._orz_decoder_destroy_v1(handle); throw error; }
  } finally { module._free(outputPointer); module._free(formatPointer); module._free(dataPointer); }
}

function check(status: number, operation: string): void { if (status !== ORZ_OK) throw new OrzAudioCoreError(status, operation); }
