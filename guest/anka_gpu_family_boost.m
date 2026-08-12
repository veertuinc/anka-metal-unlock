// Copyright (c) 2026 Veertu Inc.
// SPDX-License-Identifier: MIT
//
// Guest inject library for Anka macOS VMs on Apple Silicon.
// Raises selected Metal capability answers inside one process.
// GPU work still uses Apple's paravirtual graphics path.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import "config.h"
#import "hooks.h"

static IMP gSavedInitGPUFamilySupport;
static AnkaGpuBoostSettings gBootSettings;
static BOOL gBootSettingsReady;

static void ankaGpuBoostOnInitGPUFamilySupport(id self, SEL selector) {
    if (gBootSettingsReady) {
        (void)AnkaGpuBoostAttachDeviceHooks(self, &gBootSettings);
    }

    if (gSavedInitGPUFamilySupport != NULL) {
        ((void(*)(id, SEL))(void *)gSavedInitGPUFamilySupport)(self, selector);
    }
}

__attribute__((constructor))
static void ankaGpuFamilyBoostEntry(void) {
    @autoreleasepool {
        if (!AnkaGpuBoostLoadSettings(&gBootSettings)) {
            return;
        }
        gBootSettingsReady = YES;

        Class baseDeviceClass = NSClassFromString(@"_MTLDevice");
        if (baseDeviceClass == Nil) {
            return;
        }

        SEL initSelector = sel_registerName("initGPUFamilySupport");
        Method initMethod = class_getInstanceMethod(baseDeviceClass, initSelector);
        if (initMethod == NULL) {
            return;
        }

        gSavedInitGPUFamilySupport = method_setImplementation(
            initMethod,
            (IMP)ankaGpuBoostOnInitGPUFamilySupport
        );
    }
}
