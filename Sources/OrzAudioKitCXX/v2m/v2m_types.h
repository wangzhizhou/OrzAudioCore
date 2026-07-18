// WASM-compatible type definitions for V2M player
#ifndef TYPES_H_WASM
#define TYPES_H_WASM

#define _CRT_SECURE_NO_DEPRECATE
#define V2TYPES

// clang/WASM: long = int = 4 bytes, __int64 doesn't exist
#define __int64 long long

#include "types.h"

// Redefine 64-bit types for clang (wasm-32)
#undef sS32
#undef sU32
#define sS32 int
#define sU32 unsigned int

// __stdcall is Windows-only, empty for WASM
#define __stdcall

// Define _M_IX86 to make inline assembly references compile
// (we replace the asm blocks with C code, but some headers check this)
#define _M_IX86 300

// Replace msinttypes with c99 types
typedef long long int64_t;
typedef unsigned long long uint64_t;

#endif
