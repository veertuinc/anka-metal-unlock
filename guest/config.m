// Copyright (c) 2026 Veertu Inc.
// SPDX-License-Identifier: MIT

#import "config.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>

static BOOL parseEnvUInt(const char *key, unsigned long long *outValue) {
    const char *text = getenv(key);
    if (text == NULL || text[0] == '\0') {
        return NO;
    }

    errno = 0;
    char *tail = NULL;
    unsigned long long value = strtoull(text, &tail, 0);
    if (errno != 0 || tail == text || tail == NULL || *tail != '\0') {
        return NO;
    }

    *outValue = value;
    return YES;
}

static BOOL envPresent(const char *key) {
    const char *text = getenv(key);
    return text != NULL && text[0] != '\0';
}

BOOL AnkaGpuBoostLoadSettings(AnkaGpuBoostSettings *outSettings) {
    if (outSettings == NULL) {
        return NO;
    }

    memset(outSettings, 0, sizeof(*outSettings));

    unsigned long long familyCeiling = 0;
    if (!parseEnvUInt("VEERTU_ANKA_GPU_APPLE_FAMILY_MAX", &familyCeiling)) {
        return NO;
    }
    // Public Apple GPU family values sit in [1001, 1999].
    if (familyCeiling < 1001ULL || familyCeiling >= 2000ULL) {
        return NO;
    }

    unsigned long long threadgroupMin = 65536ULL;
    if (envPresent("VEERTU_ANKA_GPU_THREADGROUP_MEMORY_MIN") &&
        !parseEnvUInt("VEERTU_ANKA_GPU_THREADGROUP_MEMORY_MIN", &threadgroupMin)) {
        return NO;
    }

    unsigned long long workingSetMin = 0;
    BOOL raiseWorkingSet = envPresent("VEERTU_ANKA_GPU_WORKING_SET_MIN");
    if (raiseWorkingSet &&
        !parseEnvUInt("VEERTU_ANKA_GPU_WORKING_SET_MIN", &workingSetMin)) {
        return NO;
    }

    outSettings->appleFamilyCeiling = (NSUInteger)familyCeiling;
    outSettings->threadgroupMemoryMin = (NSUInteger)threadgroupMin;
    outSettings->raiseWorkingSet = raiseWorkingSet;
    outSettings->workingSetMin = (NSUInteger)workingSetMin;
    return YES;
}
