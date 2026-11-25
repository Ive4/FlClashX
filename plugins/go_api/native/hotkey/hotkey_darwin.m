//go:build !ios && cgo

#import <AppKit/AppKit.h>
#include <Carbon/Carbon.h>
#include <dispatch/dispatch.h>
#include <pthread.h>
#include <stdint.h>

extern void flclashHotkeyPressed(uint32_t id);

enum {
    alt = 1,
    control = 2,
    meta = 4,
    shift = 8,
    hotkeySignature = 0x464c4348, // FLCH
    auxControlButtons = 8,
    flclashMediaKeyDown = 0x0a,
};

static EventHandlerRef handler;
static CFMachPortRef mediaTap;
static CFRunLoopSourceRef mediaSource;
static uint32_t mediaIDs[32][16];
static unsigned int mediaCount;

static OSStatus handleHotkey(EventHandlerCallRef next, EventRef event, void *data) {
    EventHotKeyID shortcut = {0};
    OSStatus status = GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL,
                                       sizeof(shortcut), NULL, &shortcut);
    if (status != noErr || shortcut.signature != hotkeySignature) {
        return eventNotHandledErr;
    }
    flclashHotkeyPressed(shortcut.id);
    return noErr;
}

static CGEventRef handleMedia(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *data) {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        CGEventTapEnable(mediaTap, true);
        return event;
    }
    @autoreleasepool {
        NSEvent *native = [NSEvent eventWithCGEvent:event];
        if (native.type != NSEventTypeSystemDefined || native.subtype != auxControlButtons) {
            return event;
        }
        uint32_t word = (uint32_t)native.data1;
        uint32_t key = word >> 16;
        if (key >= 32) {
            return event;
        }
        NSEventModifierFlags flags = native.modifierFlags;
        uint32_t mods = 0;
        if (flags & NSEventModifierFlagOption) mods |= alt;
        if (flags & NSEventModifierFlagControl) mods |= control;
        if (flags & NSEventModifierFlagCommand) mods |= meta;
        if (flags & NSEventModifierFlagShift) mods |= shift;
        uint32_t id = mediaIDs[key][mods];
        if (id == 0) {
            return event;
        }
        if (((word >> 8) & 0xff) == flclashMediaKeyDown) {
            flclashHotkeyPressed(id);
        }
        return NULL;
    }
}

static void stopMediaTap(void) {
    if (mediaSource != NULL) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), mediaSource, kCFRunLoopCommonModes);
        CFRelease(mediaSource);
        mediaSource = NULL;
    }
    if (mediaTap != NULL) {
        CFMachPortInvalidate(mediaTap);
        CFRelease(mediaTap);
        mediaTap = NULL;
    }
}

static OSStatus startMediaTap(void) {
    if (mediaTap != NULL) {
        return noErr;
    }
    mediaTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                                CGEventMaskBit(NSEventTypeSystemDefined), handleMedia, NULL);
    if (mediaTap == NULL) {
        return eventNotHandledErr;
    }
    mediaSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, mediaTap, 0);
    if (mediaSource == NULL) {
        stopMediaTap();
        return memFullErr;
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), mediaSource, kCFRunLoopCommonModes);
    CGEventTapEnable(mediaTap, true);
    return noErr;
}

struct shortcut {
    uint32_t key;
    uint32_t modifiers;
    uint32_t id;
    uint32_t media;
    EventHotKeyRef ref;
    OSStatus status;
};

static void registerShortcut(void *context) {
    struct shortcut *s = context;
    if (s->media) {
        uint32_t *id = &mediaIDs[s->key][s->modifiers];
        if (*id != 0) {
            s->status = eventHotKeyExistsErr;
            return;
        }
        s->status = startMediaTap();
        if (s->status == noErr) {
            *id = s->id;
            mediaCount++;
        }
        return;
    }
    EventTargetRef target = GetApplicationEventTarget();
    if (handler == NULL) {
        const EventTypeSpec type = {kEventClassKeyboard, kEventHotKeyPressed};
        s->status = InstallEventHandler(target, handleHotkey, 1, &type, NULL, &handler);
        if (s->status != noErr) {
            return;
        }
    }
    uint32_t flags = 0;
    if (s->modifiers & alt) flags |= optionKey;
    if (s->modifiers & control) flags |= controlKey;
    if (s->modifiers & meta) flags |= cmdKey;
    if (s->modifiers & shift) flags |= shiftKey;
    EventHotKeyID id = {hotkeySignature, s->id};
    s->status = RegisterEventHotKey(s->key, flags, id, target, 0, &s->ref);
}

static void unregisterShortcut(void *context) {
    struct shortcut *s = context;
    if (s->media) {
        mediaIDs[s->key][s->modifiers] = 0;
        if (--mediaCount == 0) {
            stopMediaTap();
        }
    } else {
        UnregisterEventHotKey(s->ref);
    }
}

static void onMain(void *context, dispatch_function_t function) {
    if (pthread_main_np()) {
        function(context);
    } else {
        dispatch_sync_f(dispatch_get_main_queue(), context, function);
    }
}

int32_t flclash_register_hotkey(uint32_t key, uint32_t modifiers, uint32_t id, uint32_t media, uintptr_t *ref) {
    struct shortcut s = {.key = key, .modifiers = modifiers, .id = id, .media = media};
    onMain(&s, registerShortcut);
    *ref = (uintptr_t)s.ref;
    return s.status;
}

void flclash_unregister_hotkey(uint32_t key, uint32_t modifiers, uint32_t media, uintptr_t ref) {
    struct shortcut s = {.key = key, .modifiers = modifiers, .media = media, .ref = (EventHotKeyRef)ref};
    onMain(&s, unregisterShortcut);
}
