import assert from 'node:assert/strict';
import test from 'node:test';
import { AudioDecoder, ORZ_ABI_VERSION, ORZ_END_OF_STREAM, OrzAudioCoreError, createDecoder } from '../dist/index.js';

function mockModule(overrides = {}) {
  const buffer = new ArrayBuffer(64 * 1024);
  let next = 256;
  const freed = [];
  const destroyed = [];
  const module = {
    HEAPU8: new Uint8Array(buffer), HEAPU32: new Uint32Array(buffer),
    HEAPF64: new Float64Array(buffer), HEAPF32: new Float32Array(buffer),
    _malloc(size) { const pointer = next; next += Math.ceil(Math.max(size, 1) / 8) * 8; return pointer; },
    _free(pointer) { freed.push(pointer); },
    _orz_abi_version() { return ORZ_ABI_VERSION; },
    _orz_decoder_create_memory(_data, _size, _format, _config, output) { module.HEAPU32[output >>> 2] = 77; return 0; },
    _orz_decoder_get_stream_info(_handle, output) {
      module.HEAPU32[(output + 8) >>> 2] = 44100;
      module.HEAPU32[(output + 12) >>> 2] = 2;
      module.HEAPF64[(output + 16) >>> 3] = 12.5;
      module.HEAPU32[(output + 24) >>> 2] = 1;
      module.HEAPU32[(output + 28) >>> 2] = 3;
      return 0;
    },
    _orz_decoder_render_f32(_handle, output, _frames, rendered) {
      module.HEAPU32[rendered >>> 2] = 2;
      module.HEAPF32[output >>> 2] = 0.25;
      module.HEAPF32[(output >>> 2) + 1] = -0.25;
      module.HEAPF32[(output >>> 2) + 2] = 0.5;
      module.HEAPF32[(output >>> 2) + 3] = -0.5;
      return 0;
    },
    _orz_decoder_seek() { return 0; }, _orz_decoder_select_subsong_v1() { return 0; },
    _orz_decoder_reset() { return 0; }, _orz_decoder_cancel() { return 0; },
    _orz_decoder_destroy_v1(handle) { destroyed.push(handle); },
    UTF8ToString() { return ''; },
    stringToUTF8(value, pointer) { new TextEncoder().encodeInto(`${value}\0`, module.HEAPU8.subarray(pointer)); },
    lengthBytesUTF8(value) { return new TextEncoder().encode(value).length; },
    ...overrides,
  };
  return { module, freed, destroyed };
}

test('creates, describes, renders and closes an isolated decoder', () => {
  const { module, destroyed } = mockModule();
  const decoder = createDecoder(module, new Uint8Array([1, 2, 3]), 'ym');
  assert.deepEqual(decoder.info, { sampleRate: 44100, channels: 2, duration: 12.5, subsongCount: 1, capabilities: 3 });
  assert.deepEqual([...decoder.render(2)], [0.25, -0.25, 0.5, -0.5]);
  decoder.seek(1000); decoder.selectSubsong(0); decoder.reset(); decoder.cancel();
  decoder.close(); decoder.close();
  assert.deepEqual(destroyed, [77]);
  assert.throws(() => decoder.render(1), error => error instanceof OrzAudioCoreError && error.status === -1);
});

test('returns an empty PCM block at end of stream', () => {
  const { module } = mockModule({_orz_decoder_render_f32() { return ORZ_END_OF_STREAM; }});
  const decoder = createDecoder(module, new Uint8Array([1]), 'bp');
  assert.equal(decoder.render(128).length, 0);
  decoder.close();
});

test('rejects an incompatible ABI before allocating memory', () => {
  let allocations = 0;
  const { module } = mockModule({_orz_abi_version() { return 0x0002_0000; }, _malloc() { allocations++; return 256; }});
  assert.throws(() => createDecoder(module, new Uint8Array([1]), 'ym'), error => error instanceof OrzAudioCoreError && error.status === -8);
  assert.equal(allocations, 0);
});

test('destroys the native handle when stream metadata initialization fails', () => {
  const { module, destroyed } = mockModule({_orz_decoder_get_stream_info() { return -4; }});
  assert.throws(() => createDecoder(module, new Uint8Array([1]), 'ym'), error => error instanceof OrzAudioCoreError && error.status === -4);
  assert.deepEqual(destroyed, [77]);
});
