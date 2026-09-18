#include "bario.h"

/* A bump allocator with a free list of one. Modules are tiny and short-lived per call; if
 * yours is not, link a real allocator instead — nothing here depends on this one. */

extern unsigned char __heap_base;
static uintptr_t bump = 0;

void *alloc(int32_t len) {
    if (len < 0) return 0;
    if (bump == 0) bump = (uintptr_t)&__heap_base;
    /* Eight bytes of header so dealloc can be a no-op that still type-checks. */
    uintptr_t aligned = (bump + 7u) & ~(uintptr_t)7u;
    void *out = (void *)aligned;
    bump = aligned + (uintptr_t)len + 8u;
    return out;
}

void dealloc(void *ptr, int32_t len) {
    (void)ptr;
    (void)len;
    /* Nothing to do: the bump allocator resets when the instance is rebuilt. */
}

static int32_t bario_strlen(const char *text) {
    int32_t len = 0;
    while (text && text[len]) len++;
    return len;
}

static void bario_memcpy(char *dst, const char *src, int32_t len) {
    for (int32_t i = 0; i < len; i++) dst[i] = src[i];
}

int64_t bario_return(const char *text, int32_t len) {
    if (!text || len <= 0) return BARIO_NOTHING;
    char *copy = (char *)alloc(len);
    if (!copy) return BARIO_NOTHING;
    bario_memcpy(copy, text, len);
    return bario_pack(copy, len);
}

int64_t bario_return_str(const char *text) {
    return bario_return(text, bario_strlen(text));
}

void bario_log(const char *message) { bario_log_raw(1, message, bario_strlen(message)); }
void bario_warn(const char *message) { bario_log_raw(2, message, bario_strlen(message)); }
void bario_set(const char *patch) { bario_set_raw(patch, bario_strlen(patch)); }
void bario_emit(const char *event) { bario_emit_raw(event, bario_strlen(event)); }
void bario_subscribe(const char *topic) { bario_subscribe_raw(topic, bario_strlen(topic)); }

char *bario_take(int32_t len) {
    if (len <= 0) return 0;
    char *buffer = (char *)alloc(len + 1);
    if (!buffer) return 0;
    bario_read(buffer);
    buffer[len] = 0;
    return buffer;
}

char *bario_get(const char *key) { return bario_take(bario_get_raw(key, bario_strlen(key))); }
char *bario_exec(const char *argv) { return bario_take(bario_exec_raw(argv, bario_strlen(argv))); }
char *bario_read_file(const char *path) {
    return bario_take(bario_read_file_raw(path, bario_strlen(path)));
}
char *bario_http(const char *request) {
    return bario_take(bario_http_raw(request, bario_strlen(request)));
}

/* --- bario_buf ---------------------------------------------------------- */

bario_buf bario_buf_new(int32_t capacity) {
    bario_buf buf;
    if (capacity < 64) capacity = 64;
    buf.data = (char *)alloc(capacity);
    buf.len = 0;
    buf.capacity = buf.data ? capacity : 0;
    return buf;
}

static void bario_buf_grow(bario_buf *buf, int32_t needed) {
    if (buf->len + needed <= buf->capacity) return;
    int32_t capacity = buf->capacity * 2;
    while (capacity < buf->len + needed) capacity *= 2;
    char *bigger = (char *)alloc(capacity);
    if (!bigger) return;
    bario_memcpy(bigger, buf->data, buf->len);
    buf->data = bigger;
    buf->capacity = capacity;
}

void bario_buf_str(bario_buf *buf, const char *text) {
    int32_t len = bario_strlen(text);
    bario_buf_grow(buf, len);
    if (buf->len + len > buf->capacity) return;
    bario_memcpy(buf->data + buf->len, text, len);
    buf->len += len;
}

void bario_buf_escaped(bario_buf *buf, const char *text) {
    for (int32_t i = 0; text && text[i]; i++) {
        char c = text[i];
        bario_buf_grow(buf, 6);
        if (c == '"' || c == '\\') {
            buf->data[buf->len++] = '\\';
            buf->data[buf->len++] = c;
        } else if (c == '\n') {
            buf->data[buf->len++] = '\\';
            buf->data[buf->len++] = 'n';
        } else if ((unsigned char)c < 0x20) {
            static const char *hex = "0123456789abcdef";
            buf->data[buf->len++] = '\\';
            buf->data[buf->len++] = 'u';
            buf->data[buf->len++] = '0';
            buf->data[buf->len++] = '0';
            buf->data[buf->len++] = hex[((unsigned char)c >> 4) & 0xF];
            buf->data[buf->len++] = hex[(unsigned char)c & 0xF];
        } else {
            buf->data[buf->len++] = c;
        }
    }
}

void bario_buf_int(bario_buf *buf, int64_t value) {
    char digits[24];
    int32_t count = 0;
    int negative = value < 0;
    uint64_t magnitude = negative ? (uint64_t)(-value) : (uint64_t)value;
    do {
        digits[count++] = (char)('0' + (magnitude % 10));
        magnitude /= 10;
    } while (magnitude > 0);
    bario_buf_grow(buf, count + 1);
    if (negative) buf->data[buf->len++] = '-';
    while (count > 0) buf->data[buf->len++] = digits[--count];
}

void bario_buf_free(bario_buf *buf) {
    dealloc(buf->data, buf->capacity);
    buf->data = 0;
    buf->len = 0;
    buf->capacity = 0;
}

int64_t bario_buf_return(bario_buf *buf) {
    if (!buf->data || buf->len <= 0) return BARIO_NOTHING;
    return bario_pack(buf->data, buf->len);
}
