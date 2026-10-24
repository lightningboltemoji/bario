// bariowasm — bario's WASM engine: a narrow C ABI over wasmtime's Pulley interpreter.
// Implemented in src/lib.rs; driven by Sources/BarioKit/Wasm/WasmtimeEngine.swift.
#ifndef BARIOWASM_H
#define BARIOWASM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct BwEngine bw_engine;
typedef struct BwModule bw_module;
typedef struct BwInstance bw_instance;
typedef struct BwCaller bw_caller;

typedef enum {
  BW_OK = 0,
  BW_DEADLINE = 1, // the deadline passed; the guest was interrupted
  BW_TRAP = 2,     // any other way the guest failed: a trap, a host import that failed
  BW_ERROR = 3,    // the call could not be made: no such export, a bad range, no memory
} bw_status;

typedef enum {
  BW_I32 = 0,
  BW_I64 = 1,
} bw_type;

// A host import, in the `bario` namespace.
typedef struct {
  const char *name;
  const bw_type *params;
  size_t nparams;
  const bw_type *results;
  size_t nresults;
} bw_import;

// Every host import's body: `index` is its place in the array bw_instance_new was given, `args` its
// parameters widened to int64, and it writes its results the same way. It returns false after
// bw_caller_fail, and the guest traps with that message.
typedef bool (*bw_host_fn)(void *ctx, size_t index, bw_caller *caller, const int64_t *args, size_t nargs,
                           int64_t *results, size_t nresults);

// Errors come back through `err` as a C string the caller frees with bw_string_free.
bw_engine *bw_engine_new(char **err);
void bw_engine_free(bw_engine *engine);

// WebAssembly text in, the binary out: free it with bw_bytes_free.
bw_status bw_wat2wasm(const uint8_t *text, size_t len, uint8_t **out, size_t *out_len, char **err);

// A binary module, validated and compiled.
bw_module *bw_module_compile(const bw_engine *engine, const uint8_t *wasm, size_t len, char **err);
void bw_module_free(bw_module *module);

// The instance keeps what it needs of the module, which may be freed after. Its start function, if it
// has one, gets a second.
bw_instance *bw_instance_new(const bw_engine *engine, const bw_module *module, uint64_t memory_cap,
                             const bw_import *imports, size_t nimports, bw_host_fn call, void *ctx, char **err);
void bw_instance_free(bw_instance *instance);

// Every call from now on, together, ends `seconds` from now: past it, the guest is interrupted.
void bw_instance_set_deadline(bw_instance *instance, double seconds);
// Whether `name` is an exported function, and its parameter and result counts. Either may be null.
bool bw_instance_func(bw_instance *instance, const char *name, size_t *nparams, size_t *nresults);
bw_status bw_instance_call(bw_instance *instance, const char *name, const int64_t *args, size_t nargs,
                           int64_t *results, size_t nresults, char **err);
bw_status bw_instance_read(const bw_instance *instance, uint32_t ptr, uint8_t *out, size_t len, char **err);
bw_status bw_instance_write(bw_instance *instance, uint32_t ptr, const uint8_t *bytes, size_t len, char **err);

// The guest's memory from inside a host import.
bw_status bw_caller_read(bw_caller *caller, uint32_t ptr, uint8_t *out, size_t len, char **err);
bw_status bw_caller_write(bw_caller *caller, uint32_t ptr, const uint8_t *bytes, size_t len, char **err);
void bw_caller_fail(bw_caller *caller, const char *message);

void bw_bytes_free(uint8_t *ptr, size_t len);
void bw_string_free(char *s);

#ifdef __cplusplus
}
#endif

#endif
