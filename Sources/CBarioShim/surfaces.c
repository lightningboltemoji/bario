#include "include/bario_shim.h"

#include <mach/mach.h>
#include <mach/notify.h>
#include <servers/bootstrap.h>
#include <string.h>

#define HANDOFF_ID 0x62617273   /* 'bars' */
#define ANSWER_ID  0x62617274

typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t surfaces[2];
    mach_msg_port_descriptor_t owner;
    char name[BARIO_SURFACE_NAME_MAX];
} handoff_message;

typedef struct {
    mach_msg_header_t header;
    int32_t status;
} answer_message;

mach_port_t bario_surfaces_listen(const char *service, kern_return_t *error) {
    mach_port_t port = MACH_PORT_NULL;
    kern_return_t kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port);
    if (kr == KERN_SUCCESS) {
        kr = mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND);
    }
    if (kr == KERN_SUCCESS) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        kr = bootstrap_register(bootstrap_port, (char *)service, port);
#pragma clang diagnostic pop
    }
    if (kr != KERN_SUCCESS) {
        if (port != MACH_PORT_NULL) {
            mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
            mach_port_deallocate(mach_task_self(), port);
        }
        if (error) *error = kr;
        return MACH_PORT_NULL;
    }
    if (error) *error = KERN_SUCCESS;
    return port;
}

void bario_surfaces_close(mach_port_t listener) {
    if (listener == MACH_PORT_NULL) return;
    /* Destroying the receive right removes the name from the namespace with it. */
    mach_port_mod_refs(mach_task_self(), listener, MACH_PORT_RIGHT_RECEIVE, -1);
    mach_port_deallocate(mach_task_self(), listener);
}

int bario_surfaces_receive(mach_port_t listener, bario_surfaces_event *event) {
    for (;;) {
        union {
            mach_msg_header_t header;
            char bytes[sizeof(handoff_message) + MAX_TRAILER_SIZE + 64];
        } buffer;
        memset(&buffer, 0, sizeof buffer);
        kern_return_t kr = mach_msg(&buffer.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0,
                                    sizeof buffer, listener, 0, MACH_PORT_NULL);
        if (kr != MACH_MSG_SUCCESS) return 0;

        memset(event, 0, sizeof *event);
        switch (buffer.header.msgh_id) {
        case MACH_NOTIFY_DEAD_NAME: {
            mach_dead_name_notification_t *notification = (mach_dead_name_notification_t *)&buffer.header;
            event->kind = BARIO_SURFACES_OWNER_GONE;
            event->owner = notification->not_port;
            /* The notification carries a reference of its own; the receiver keeps its one. */
            mach_port_deallocate(mach_task_self(), notification->not_port);
            return 1;
        }
        case HANDOFF_ID: {
            handoff_message *message = (handoff_message *)&buffer.header;
            if (!(message->header.msgh_bits & MACH_MSGH_BITS_COMPLEX)
                || message->header.msgh_size < sizeof(handoff_message)
                || message->body.msgh_descriptor_count != 3) {
                mach_msg_destroy(&buffer.header);
                continue;
            }
            event->kind = BARIO_SURFACES_HANDOFF;
            memcpy(event->name, message->name, BARIO_SURFACE_NAME_MAX);
            event->name[BARIO_SURFACE_NAME_MAX - 1] = 0;
            event->surfaces[0] = message->surfaces[0].name;
            event->surfaces[1] = message->surfaces[1].name;
            event->owner = message->owner.name;
            event->reply = message->header.msgh_remote_port;
            return 1;
        }
        default:
            /* Port-deleted and send-once notifications, and anything else: nothing to do. */
            mach_msg_destroy(&buffer.header);
            continue;
        }
    }
}

kern_return_t bario_surfaces_watch(mach_port_t listener, mach_port_t owner) {
    mach_port_t previous = MACH_PORT_NULL;
    kern_return_t kr = mach_port_request_notification(mach_task_self(), owner, MACH_NOTIFY_DEAD_NAME,
                                                      0, listener, MACH_MSG_TYPE_MAKE_SEND_ONCE,
                                                      &previous);
    if (previous != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), previous);
    return kr;
}

kern_return_t bario_surfaces_answer(mach_port_t reply, int status) {
    if (reply == MACH_PORT_NULL) return KERN_INVALID_ARGUMENT;
    answer_message message;
    memset(&message, 0, sizeof message);
    message.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
    message.header.msgh_size = sizeof message;
    message.header.msgh_remote_port = reply;
    message.header.msgh_id = ANSWER_ID;
    message.status = status;
    kern_return_t kr = mach_msg(&message.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof message,
                                0, MACH_PORT_NULL, 100, MACH_PORT_NULL);
    if (kr != MACH_MSG_SUCCESS) mach_port_deallocate(mach_task_self(), reply);
    return kr;
}

int bario_surfaces_hand_off(const char *service, const char *name, mach_port_t surface0,
                            mach_port_t surface1, mach_port_t owner, int timeout_ms) {
    mach_port_t destination = MACH_PORT_NULL;
    if (bootstrap_look_up(bootstrap_port, service, &destination) != KERN_SUCCESS) return -1;

    mach_port_t reply = MACH_PORT_NULL;
    if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &reply) != KERN_SUCCESS) {
        mach_port_deallocate(mach_task_self(), destination);
        return -1;
    }

    handoff_message message;
    memset(&message, 0, sizeof message);
    message.header.msgh_bits = MACH_MSGH_BITS_COMPLEX
        | MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
    message.header.msgh_size = sizeof message;
    message.header.msgh_remote_port = destination;
    message.header.msgh_local_port = reply;
    message.header.msgh_id = HANDOFF_ID;
    message.body.msgh_descriptor_count = 3;
    mach_port_t ports[3] = { surface0, surface1, owner };
    mach_msg_type_name_t dispositions[3] = { MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_COPY_SEND,
                                             MACH_MSG_TYPE_MAKE_SEND };
    for (int i = 0; i < 3; i++) {
        mach_msg_port_descriptor_t *descriptor = i < 2 ? &message.surfaces[i] : &message.owner;
        descriptor->name = ports[i];
        descriptor->disposition = dispositions[i];
        descriptor->type = MACH_MSG_PORT_DESCRIPTOR;
    }
    strlcpy(message.name, name, BARIO_SURFACE_NAME_MAX);

    int status = -1;
    kern_return_t kr = mach_msg(&message.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof message,
                                0, MACH_PORT_NULL, (mach_msg_timeout_t)timeout_ms, MACH_PORT_NULL);
    if (kr == MACH_MSG_SUCCESS) {
        struct { answer_message answer; mach_msg_trailer_t trailer; } buffer;
        memset(&buffer, 0, sizeof buffer);
        kr = mach_msg(&buffer.answer.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof buffer, reply,
                      (mach_msg_timeout_t)timeout_ms, MACH_PORT_NULL);
        if (kr == MACH_MSG_SUCCESS && buffer.answer.header.msgh_id == ANSWER_ID) {
            status = buffer.answer.status;
        }
    }
    mach_port_mod_refs(mach_task_self(), reply, MACH_PORT_RIGHT_RECEIVE, -1);
    mach_port_deallocate(mach_task_self(), destination);
    return status;
}
