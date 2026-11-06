#include "include/bario_shim.h"

#include <IOKit/IOKitLib.h>
#include <stdint.h>
#include <string.h>

/* AppleSMC's user client has one struct method, and everything goes through it as this message,
 * with `command` saying what to do. No header declares any of it; the layout is the driver's. */
enum {
    SMC_METHOD = 2,
    SMC_COMMAND_READ = 5,
    SMC_COMMAND_KEY_INFO = 9,
};

typedef struct {
    uint8_t major, minor, build, reserved;
    uint16_t release;
} smc_version;

typedef struct {
    uint16_t version, length;
    uint32_t cpu_limit, gpu_limit, memory_limit;
} smc_limits;

typedef struct {
    uint32_t size;
    uint32_t type;
    uint8_t attributes;
} smc_key_info;

typedef struct {
    uint32_t key;
    smc_version version;
    smc_limits limits;
    smc_key_info info;
    uint8_t result;
    uint8_t status;
    uint8_t command;
    uint32_t argument;
    uint8_t bytes[32];
} smc_message;

_Static_assert(sizeof(smc_message) == 80, "the driver refuses a message of any other size");

static uint32_t four_char_code(const char *text) {
    return (uint32_t)text[0] << 24 | (uint32_t)text[1] << 16 | (uint32_t)text[2] << 8 | (uint32_t)text[3];
}

static int smc_call(mach_port_t connection, const smc_message *in, smc_message *out) {
    size_t size = sizeof *out;
    memset(out, 0, size);
    return IOConnectCallStructMethod(connection, SMC_METHOD, in, sizeof *in, out, &size) == KERN_SUCCESS
        && out->result == 0;
}

mach_port_t bario_smc_open(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (service == IO_OBJECT_NULL) return MACH_PORT_NULL;
    io_connect_t connection = IO_OBJECT_NULL;
    kern_return_t status = IOServiceOpen(service, mach_task_self(), 0, &connection);
    IOObjectRelease(service);
    return status == KERN_SUCCESS ? connection : MACH_PORT_NULL;
}

int bario_smc_read_float(mach_port_t connection, const char *key, float *value) {
    if (strlen(key) != 4) return 0;

    smc_message in = {.key = four_char_code(key), .command = SMC_COMMAND_KEY_INFO};
    smc_message out;
    if (!smc_call(connection, &in, &out)) return 0;
    if (out.info.size != sizeof(float) || out.info.type != four_char_code("flt ")) return 0;

    in.info = out.info;
    in.command = SMC_COMMAND_READ;
    if (!smc_call(connection, &in, &out)) return 0;
    memcpy(value, out.bytes, sizeof(float));
    return 1;
}
