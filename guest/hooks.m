// Copyright (c) 2026 Veertu Inc.
// SPDX-License-Identifier: MIT

#import "hooks.h"

#import <objc/runtime.h>
#import <dispatch/dispatch.h>

#include <string.h>

enum {
    kHookSupportsFamily = 0,
    kHookMaxThreadgroup,
    kHookWorkingSet,
    kHookCount
};

typedef struct {
    const char *selectorName;
    IMP replacement;
    IMP original;
    BOOL required;
    BOOL active;
} AnkaGpuHookSlot;

static AnkaGpuBoostSettings gSettings;
static AnkaGpuHookSlot gSlots[kHookCount];
static dispatch_once_t gAttachOnce;
static BOOL gAttachSucceeded;

static BOOL boostedSupportsFamily(id self, SEL selector, NSUInteger family) {
    IMP original = gSlots[kHookSupportsFamily].original;
    BOOL stock = NO;
    if (original != NULL) {
        stock = ((BOOL(*)(id, SEL, NSUInteger))(void *)original)(
            self,
            selector,
            family
        );
    }

    BOOL inAppleCeiling =
        family >= 1001 && family <= gSettings.appleFamilyCeiling;
    return stock || inAppleCeiling;
}

static NSUInteger boostedMaxThreadgroupMemory(id self, SEL selector) {
    IMP original = gSlots[kHookMaxThreadgroup].original;
    NSUInteger stock = 0;
    if (original != NULL) {
        stock = ((NSUInteger(*)(id, SEL))(void *)original)(self, selector);
    }
    if (stock < gSettings.threadgroupMemoryMin) {
        return gSettings.threadgroupMemoryMin;
    }
    return stock;
}

static NSUInteger boostedWorkingSetSize(id self, SEL selector) {
    IMP original = gSlots[kHookWorkingSet].original;
    NSUInteger stock = 0;
    if (original != NULL) {
        stock = ((NSUInteger(*)(id, SEL))(void *)original)(self, selector);
    }
    if (stock < gSettings.workingSetMin) {
        return gSettings.workingSetMin;
    }
    return stock;
}

static void fillSlotTable(BOOL includeWorkingSet) {
    memset(gSlots, 0, sizeof(gSlots));

    gSlots[kHookSupportsFamily] = (AnkaGpuHookSlot){
        .selectorName = "supportsFamily:",
        .replacement = (IMP)boostedSupportsFamily,
        .required = YES,
    };
    gSlots[kHookMaxThreadgroup] = (AnkaGpuHookSlot){
        .selectorName = "maxThreadgroupMemoryLength",
        .replacement = (IMP)boostedMaxThreadgroupMemory,
        .required = YES,
    };
    gSlots[kHookWorkingSet] = (AnkaGpuHookSlot){
        .selectorName = "recommendedMaxWorkingSetSize",
        .replacement = (IMP)boostedWorkingSetSize,
        .required = includeWorkingSet,
    };
}

static Method methodForSlot(Class deviceClass, const AnkaGpuHookSlot *slot) {
    return class_getInstanceMethod(
        deviceClass,
        sel_registerName(slot->selectorName)
    );
}

static BOOL applySlot(Class deviceClass, AnkaGpuHookSlot *slot) {
    Method method = methodForSlot(deviceClass, slot);
    if (method == NULL) {
        return NO;
    }

    IMP previous = method_setImplementation(method, slot->replacement);
    if (previous == NULL) {
        return NO;
    }

    slot->original = previous;
    slot->active = YES;
    return YES;
}

static void restoreActiveSlots(Class deviceClass) {
    for (size_t index = 0; index < kHookCount; index++) {
        AnkaGpuHookSlot *slot = &gSlots[index];
        if (!slot->active || slot->original == NULL) {
            continue;
        }

        Method method = methodForSlot(deviceClass, slot);
        if (method != NULL) {
            method_setImplementation(method, slot->original);
        }
        slot->active = NO;
        slot->original = NULL;
    }
}

static BOOL installSlotTable(Class deviceClass) {
    for (size_t index = 0; index < kHookCount; index++) {
        AnkaGpuHookSlot *slot = &gSlots[index];
        if (slot->selectorName == NULL) {
            continue;
        }

        // Skip optional working-set override when the caller did not request it.
        if (index == kHookWorkingSet && !slot->required) {
            continue;
        }

        Method method = methodForSlot(deviceClass, slot);
        if (method == NULL) {
            NSLog(
                @"[AnkaGpuFamilyBoost] missing selector %s; "
                @"leaving Metal answers stock",
                slot->selectorName
            );
            restoreActiveSlots(deviceClass);
            return NO;
        }

        if (!applySlot(deviceClass, slot)) {
            NSLog(
                @"[AnkaGpuFamilyBoost] failed to attach %s; rolling back",
                slot->selectorName
            );
            restoreActiveSlots(deviceClass);
            return NO;
        }
    }

    return YES;
}

BOOL AnkaGpuBoostAttachDeviceHooks(
    id device,
    const AnkaGpuBoostSettings *settings
) {
    if (device == nil || settings == NULL) {
        return NO;
    }

    dispatch_once(&gAttachOnce, ^{
        gSettings = *settings;
        fillSlotTable(settings->raiseWorkingSet);

        Class deviceClass = [device class];
        gAttachSucceeded = installSlotTable(deviceClass);

        if (gAttachSucceeded) {
            NSLog(
                @"[AnkaGpuFamilyBoost] active in %@ "
                @"(appleFamilyCeiling=%lu threadgroupMemoryMin=%lu)",
                [NSProcessInfo processInfo].processName,
                (unsigned long)gSettings.appleFamilyCeiling,
                (unsigned long)gSettings.threadgroupMemoryMin
            );
        }
    });

    return gAttachSucceeded;
}
