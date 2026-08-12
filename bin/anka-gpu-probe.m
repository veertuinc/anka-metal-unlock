// Copyright (c) 2026 Veertu Inc.
// SPDX-License-Identifier: MIT
//
// Prints default-device Metal answers as one JSON object.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>

static BOOL parseFamily(const char *raw, NSUInteger *familyOut) {
    errno = 0;
    char *tail = NULL;
    unsigned long long value = strtoull(raw, &tail, 0);
    if (errno != 0 || tail == raw || tail == NULL || *tail != '\0') {
        return NO;
    }
    *familyOut = (NSUInteger)value;
    return YES;
}

static void printJsonEscaped(const char *text) {
    fputc('"', stdout);
    if (text != NULL) {
        for (const unsigned char *cursor = (const unsigned char *)text;
             *cursor != '\0';
             cursor++) {
            unsigned char ch = *cursor;
            if (ch == '"' || ch == '\\') {
                fputc('\\', stdout);
                fputc((int)ch, stdout);
            } else if (ch < 0x20) {
                fprintf(stdout, "\\u%04x", ch);
            } else {
                fputc((int)ch, stdout);
            }
        }
    }
    fputc('"', stdout);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSUInteger family = 1009;
        if (argc > 1 && !parseFamily(argv[1], &family)) {
            fprintf(stderr, "invalid family: %s\n", argv[1]);
            return 2;
        }

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device == nil) {
            fprintf(stderr, "Metal device unavailable\n");
            return 1;
        }

        BOOL supports = [device supportsFamily:(MTLGPUFamily)family];
        unsigned long long threadgroup =
            (unsigned long long)device.maxThreadgroupMemoryLength;

        fputc('{', stdout);
        fputs("\"device\":", stdout);
        printJsonEscaped(device.name.UTF8String);
        fprintf(stdout, ",\"family\":%llu", (unsigned long long)family);
        fprintf(
            stdout,
            ",\"supports_family\":%s",
            supports ? "true" : "false"
        );
        fprintf(
            stdout,
            ",\"max_threadgroup_memory\":%llu",
            threadgroup
        );
        fputs("}\n", stdout);
    }
    return 0;
}
