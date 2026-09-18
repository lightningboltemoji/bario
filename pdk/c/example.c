/* The smallest useful bario module in C: a bubble that counts its own polls.
 *
 *   item "ticks" module="wasm" path="~/.config/bario/modules/example.wasm" interval="1s"
 */
#include "bario.h"

static int64_t ticks = 0;

__attribute__((export_name("init")))
int64_t init(const char *ptr, int32_t len) {
    (void)ptr;
    (void)len;
    bario_log("counter ready");
    return BARIO_NOTHING;
}

__attribute__((export_name("poll")))
int64_t poll(const char *ptr, int32_t len) {
    (void)ptr;
    (void)len;
    ticks++;
    bario_buf patch = bario_buf_new(64);
    bario_buf_str(&patch, "{\"ticks\":");
    bario_buf_int(&patch, ticks);
    bario_buf_str(&patch, "}");
    return bario_buf_return(&patch);
}

__attribute__((export_name("render")))
int64_t render(const char *ptr, int32_t len) {
    (void)ptr;
    (void)len;
    bario_buf out = bario_buf_new(128);
    bario_buf_str(&out, "{\"content\":{\"row\":{\"gap\":4,\"children\":[");
    bario_buf_str(&out, "{\"icon\":\"timer\",\"class\":\"icon\"},");
    bario_buf_str(&out, "{\"text\":\"");
    bario_buf_int(&out, ticks);
    bario_buf_str(&out, "\",\"class\":\"count\"}]}}}");
    return bario_buf_return(&out);
}
