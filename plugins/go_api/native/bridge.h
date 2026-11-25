#pragma once

#include <stdint.h>
#include <stdlib.h>

typedef void (*EventCallback)(int64_t, int32_t, uint8_t *, intptr_t);

static inline void deliver_event(EventCallback callback, int64_t id, int32_t kind, uint8_t *data, intptr_t length) {
    callback(id, kind, data, length);
}
