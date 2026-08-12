// Copyright (c) 2026 Veertu Inc.
// SPDX-License-Identifier: MIT

#ifndef ANKA_GPU_FAMILY_BOOST_HOOKS_H
#define ANKA_GPU_FAMILY_BOOST_HOOKS_H

#import <Foundation/Foundation.h>
#import "config.h"

/// Attach process-local Metal answer overrides for one device class.
/// Safe to call more than once; install runs at most one time.
BOOL AnkaGpuBoostAttachDeviceHooks(
    id device,
    const AnkaGpuBoostSettings *settings
);

#endif
