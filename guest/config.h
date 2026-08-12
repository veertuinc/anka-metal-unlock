// Copyright (c) 2026 Veertu Inc.
// SPDX-License-Identifier: MIT

#ifndef ANKA_GPU_FAMILY_BOOST_CONFIG_H
#define ANKA_GPU_FAMILY_BOOST_CONFIG_H

#import <Foundation/Foundation.h>

typedef struct {
    NSUInteger appleFamilyCeiling;
    NSUInteger threadgroupMemoryMin;
    BOOL raiseWorkingSet;
    NSUInteger workingSetMin;
} AnkaGpuBoostSettings;

/// Read VEERTU_ANKA_GPU_* from the process environment.
/// Returns YES only when the required family ceiling is valid.
BOOL AnkaGpuBoostLoadSettings(AnkaGpuBoostSettings *outSettings);

#endif
