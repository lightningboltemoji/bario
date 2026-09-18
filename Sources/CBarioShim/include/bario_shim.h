/* Small C shims for calls Swift cannot reach.
 *
 * `shm_open` is declared variadic in the Darwin SDK, which makes it unavailable to Swift, and
 * a POSIX shared memory object is not in the filesystem namespace so `open(2)` cannot stand in
 * for it.
 *
 * `bootstrap.h` is not visible to Swift at all, and handing bario a pair of IOSurfaces is a Mach
 * message with port rights in it (DESIGN.md §9), which Swift has no way to build.
 */
#ifndef BARIO_SHIM_H
#define BARIO_SHIM_H

#include <sys/types.h>
#include <mach/mach.h>

/* Opens a POSIX shared memory object read-only. Returns a file descriptor, or -1. */
int bario_shm_open_readonly(const char *name);

/* --- Shared surfaces --------------------------------------------------------------------- */

/* The longest surface name, terminator included. */
#define BARIO_SURFACE_NAME_MAX 128

/* How bario answers a hand-off. */
#define BARIO_SURFACES_ACCEPTED 0
/* Another producer that is still running holds the name. */
#define BARIO_SURFACES_TAKEN 1
/* The ports were not two IOSurfaces. */
#define BARIO_SURFACES_INVALID 2

/* Publishes a receive right under `service` in this login session's bootstrap namespace, for
 * producers to find. An app a user opens has no launchd-given name to listen on, so this is
 * `bootstrap_register`, deprecated since macOS 10.5 and working on macOS 27; everything else
 * about surfaces is independent of it. Returns the receive right, or MACH_PORT_NULL with
 * `*error` set. */
mach_port_t bario_surfaces_listen(const char *service, kern_return_t *error);

/* Gives the name back and destroys the receive right. */
void bario_surfaces_close(mach_port_t listener);

typedef enum {
    BARIO_SURFACES_NOTHING = 0,
    /* A producer handed over surfaces. */
    BARIO_SURFACES_HANDOFF = 1,
    /* A producer that handed over surfaces has gone. */
    BARIO_SURFACES_OWNER_GONE = 2,
} bario_surfaces_event_kind;

typedef struct {
    bario_surfaces_event_kind kind;
    char name[BARIO_SURFACE_NAME_MAX];
    /* Send rights for `IOSurfaceLookupFromMachPort`; the receiver deallocates them. */
    mach_port_t surfaces[2];
    /* The producer. For a hand-off, a send right whose death is the producer's; for
     * OWNER_GONE, the dead name, whose one reference the receiver still holds. */
    mach_port_t owner;
    /* Answer a hand-off exactly once, with `bario_surfaces_answer`. */
    mach_port_t reply;
} bario_surfaces_event;

/* Takes one message off the listener without waiting. Returns 1 and fills `event` if there was
 * one worth reporting, 0 when the queue is empty. */
int bario_surfaces_receive(mach_port_t listener, bario_surfaces_event *event);

/* Asks for OWNER_GONE on the listener when `owner` dies. */
kern_return_t bario_surfaces_watch(mach_port_t listener, mach_port_t owner);

kern_return_t bario_surfaces_answer(mach_port_t reply, int status);

/* The producer's side: hands `surface0` and `surface1` (from `IOSurfaceCreateMachPort`, which
 * the caller still owns and deallocates) to the bario listening on `service`, under `name`.
 * `owner` is a receive right the producer keeps for as long as the surfaces should live.
 * Returns a BARIO_SURFACES_ status, or -1 if nothing answered within `timeout_ms`. */
int bario_surfaces_hand_off(const char *service, const char *name, mach_port_t surface0,
                            mach_port_t surface1, mach_port_t owner, int timeout_ms);

#endif /* BARIO_SHIM_H */
