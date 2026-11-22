// Boots a UGen300 that is in loader mode by uploading the HailoRT runtime root filesystem to its RAM.
// Sequence reconstructed by a third party from USB captures of Hailo's loader (see the project log).
#ifndef UGENLOADER_H
#define UGENLOADER_H

#include "ugenrt.h"

#ifdef __cplusplus
extern "C" {
#endif

#define UGEN_LOADER_EXPECTED_PROTOCOL 1u
#define UGEN_LOADER_EXPECTED_BUILD "Hailo Linux build v1.10.10"  // loader that accepts the 5.3.0 runtime
#define UGEN_LOADER_ENDPOINT_OUT 0x01

enum {
    UGEN_ERR_LOADER_PROTOCOL = 0x10010,   // loader protocol version is not the supported one
    UGEN_ERR_LOADER_BUILD = 0x10011,      // loader build string does not match the image's loader
    UGEN_ERR_LOADER_NOT_READY = 0x10012,  // loader did not report ready for data
};

typedef struct ugen_loader_info {
    uint32_t protocol;
    char sku[65];
    char build[65];
} ugen_loader_info;

// Reads the loader's protocol version, SKU and build string. Read-only.
// On UGEN_ERR_TRANSPORT, *transport_error holds the platform error.
int ugen_loader_probe(const ugen_transport *transport, ugen_loader_info *info, int *transport_error);

// Called after each chunk with the bytes sent so far. May be NULL.
typedef void (*ugen_loader_progress)(void *context, uint32_t sent, uint32_t total);

// Validates the loader, then uploads `image`. The device re-enumerates in runtime mode a few seconds
// after this returns UGEN_OK. `sleep_ms` is supplied by the platform.
int ugen_loader_upload(const ugen_transport *transport, const void *image, uint32_t image_size,
                       void (*sleep_ms)(uint32_t ms), ugen_loader_progress progress, void *progress_context,
                       int *transport_error);

#ifdef __cplusplus
}
#endif

#endif
