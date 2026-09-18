/* Write a bario module in C.
 *
 * A module is a WebAssembly file that exports `render`, and optionally `init`, `poll` and
 * `on_event`. This header is the whole ABI: the packed (ptr, len) return, the allocator the
 * host uses to hand you bytes, and the host imports.
 *
 * Build it with the wasi-sdk (or any clang with wasm-ld):
 *
 *   clang --target=wasm32 -nostdlib -O2 \
 *       -Wl,--no-entry -Wl,--export=render -Wl,--export=alloc -Wl,--export=memory \
 *       -o mymodule.wasm mymodule.c bario.c
 *
 * You write JSON by hand here, which is the price of no dependencies. bario_buf is enough
 * for that; see examples in the repo.
 */
#ifndef BARIO_H
#define BARIO_H

#include <stddef.h>
#include <stdint.h>

/* --- The ABI ------------------------------------------------------------ */

/* The host calls this to get a buffer it can write bytes into. */
__attribute__((export_name("alloc"))) void *alloc(int32_t len);
__attribute__((export_name("dealloc"))) void dealloc(void *ptr, int32_t len);

/* (ptr, len) packed into one i64: high 32 bits the pointer, low 32 the length. */
static inline int64_t bario_pack(const void *ptr, int32_t len) {
    return ((int64_t)(uint32_t)(uintptr_t)ptr << 32) | (uint32_t)len;
}

/* Nothing to say. */
#define BARIO_NOTHING ((int64_t)0)

/* Copy `text` into a fresh buffer and pack it, which is what `render` returns. */
int64_t bario_return(const char *text, int32_t len);
int64_t bario_return_str(const char *text);

/* --- Host imports ------------------------------------------------------- */

#define BARIO_IMPORT(name) __attribute__((import_module("bario"), import_name(name)))

BARIO_IMPORT("log") void bario_log_raw(int32_t level, const char *ptr, int32_t len);
BARIO_IMPORT("now") int64_t bario_now(void);
BARIO_IMPORT("set") void bario_set_raw(const char *ptr, int32_t len);
BARIO_IMPORT("get") int32_t bario_get_raw(const char *ptr, int32_t len);
BARIO_IMPORT("read") void bario_read(void *ptr);
BARIO_IMPORT("emit") void bario_emit_raw(const char *ptr, int32_t len);
BARIO_IMPORT("subscribe") void bario_subscribe_raw(const char *ptr, int32_t len);
BARIO_IMPORT("set_timer") int32_t bario_set_timer(int32_t ms);
/* From `draw` only: draw this node again in the next frame, at the display's rate. A call made
   while measuring asks for nothing. `draw` runs when the host commits a frame, and the `frame`
   it is given is node-local: x and y are 0, width and height the node's size. A drawing that
   only turns, moves or fades is cheaper as a CSS `animation`, which costs no frames at all. */
BARIO_IMPORT("request_frame") void bario_request_frame(void);
BARIO_IMPORT("exec") int32_t bario_exec_raw(const char *ptr, int32_t len);
BARIO_IMPORT("read_file") int32_t bario_read_file_raw(const char *ptr, int32_t len);
BARIO_IMPORT("http") int32_t bario_http_raw(const char *ptr, int32_t len);

/* Convenience wrappers over the raw imports. */
void bario_log(const char *message);
void bario_warn(const char *message);
void bario_set(const char *patch_json);
void bario_emit(const char *event_json);
void bario_subscribe(const char *topic_json);

/* A host import that produces bytes returns their length and stashes them; this copies them
 * into a buffer you own. Free it with dealloc(). Returns NULL when there is nothing. */
char *bario_take(int32_t len);

/* get / exec / read_file / http, each returning a freshly allocated JSON string or NULL. */
char *bario_get(const char *key_json);
char *bario_exec(const char *argv_json);
char *bario_read_file(const char *path_json);
char *bario_http(const char *request_json);

/* --- A very small string builder --------------------------------------- */

typedef struct {
    char *data;
    int32_t len;
    int32_t capacity;
} bario_buf;

bario_buf bario_buf_new(int32_t capacity);
void bario_buf_str(bario_buf *buf, const char *text);
/* Appends `text` with JSON string escaping, without the surrounding quotes. */
void bario_buf_escaped(bario_buf *buf, const char *text);
void bario_buf_int(bario_buf *buf, int64_t value);
void bario_buf_free(bario_buf *buf);
/* Packs the buffer for return, handing ownership to the host. */
int64_t bario_buf_return(bario_buf *buf);

#endif /* BARIO_H */
