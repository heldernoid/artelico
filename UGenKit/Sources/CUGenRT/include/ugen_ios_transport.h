// Platform access to the UGen300.
// iPadOS: forwards to the UGenDriver DriverKit extension's user client (ugen_ios_transport.c).
// macOS: talks to the device directly through IOKit (ugen_mac_transport.c), doing what the driver does.
#ifndef UGEN_IOS_TRANSPORT_H
#define UGEN_IOS_TRANSPORT_H

#include "ugenrt.h"

#ifdef __cplusplus
extern "C" {
#endif

// Mirrors UGenDriverInfo in the driver's UGenShared.h.
typedef struct ugen_driver_info {
    uint32_t struct_version;
    uint32_t mode;   // 1 = loader, 2 = runtime
    uint32_t ready;
    int32_t open_status;
    int32_t descriptor_status;
    int32_t set_config_status;
    int32_t interface_status;
    int32_t buffer_status;
    uint16_t id_vendor;
    uint16_t id_product;
    uint16_t bcd_device;
    uint8_t device_class;
    uint8_t num_configurations;
    uint32_t max_bulk_chunk;
} ugen_driver_info;

enum {
    UGEN_DRIVER_NOT_FOUND = -1,  // driver service absent: stick unplugged or driver not enabled
};

// Opens a connection to the driver. Returns 0, UGEN_DRIVER_NOT_FOUND, or an IOKit error.
int ugen_driver_open(uint32_t *connection);
void ugen_driver_close(uint32_t connection);
int ugen_driver_get_info(uint32_t connection, ugen_driver_info *info);
// Selects configuration 1 again and opens interface `interface_number` (0..4 in runtime mode).
// Returns 0 or a platform error.
int ugen_driver_reset(uint32_t *connection, uint8_t interface_number);
// Timeout for bulk transfers made through this API, in milliseconds. 0 restores the default (60 s).
void ugen_driver_set_bulk_timeout(uint32_t milliseconds);
// Fills `transport` with functions that forward to the driver. `connection` must outlive it.
void ugen_driver_make_transport(uint32_t *connection, ugen_transport *transport);

#ifdef __cplusplus
}
#endif

#endif
