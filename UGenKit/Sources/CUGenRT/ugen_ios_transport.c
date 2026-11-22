#include "ugen_ios_transport.h"

#include <TargetConditionals.h>

#if TARGET_OS_IOS && !TARGET_OS_MACCATALYST

#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <string.h>

// Selectors and limits of the driver's user client (UGenShared.h).
enum { SEL_GET_INFO = 0, SEL_CONTROL_IN = 1, SEL_CONTROL_OUT = 2, SEL_BULK_OUT = 3, SEL_BULK_IN = 4, SEL_RESET = 5 };
#define DRIVER_SERVICE_NAME "UGenDriver"

static uint32_t g_bulk_timeout_ms = 0;  // 0 = the driver's default

void ugen_driver_set_bulk_timeout(uint32_t milliseconds) {
    g_bulk_timeout_ms = milliseconds;
}

int ugen_driver_open(uint32_t *connection) {
    *connection = 0;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching(DRIVER_SERVICE_NAME));
    if (service == IO_OBJECT_NULL) return UGEN_DRIVER_NOT_FOUND;
    io_connect_t connect = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &connect);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS) return kr;
    *connection = connect;
    return 0;
}

void ugen_driver_close(uint32_t connection) {
    if (connection != 0) IOServiceClose(connection);
}

int ugen_driver_get_info(uint32_t connection, ugen_driver_info *info) {
    memset(info, 0, sizeof *info);
    size_t size = sizeof *info;
    return IOConnectCallStructMethod(connection, SEL_GET_INFO, NULL, 0, info, &size);
}

int ugen_driver_reset(uint32_t *connection, uint8_t interface_number) {
    const uint64_t in[1] = {interface_number};
    return IOConnectCallMethod(*connection, SEL_RESET, in, 1, NULL, 0, NULL, NULL, NULL, NULL);
}

static int ios_control_out(void *context, uint8_t type, uint8_t request, uint16_t value, uint16_t index,
                           const void *data, uint16_t length) {
    const uint64_t in[4] = {type, request, value, index};
    return IOConnectCallMethod(*(uint32_t *)context, SEL_CONTROL_OUT, in, 4, data, length, NULL, NULL, NULL, NULL);
}

static int ios_control_in(void *context, uint8_t type, uint8_t request, uint16_t value, uint16_t index,
                          void *data, uint16_t length, uint16_t *transferred) {
    const uint64_t in[5] = {type, request, value, index, length};
    uint64_t out[1] = {0};
    uint32_t out_count = 1;
    size_t size = length;
    kern_return_t kr = IOConnectCallMethod(*(uint32_t *)context, SEL_CONTROL_IN, in, 5, NULL, 0, out, &out_count, data, &size);
    *transferred = (uint16_t)out[0];
    return kr;
}

static int ios_bulk_out(void *context, uint8_t endpoint, const void *data, uint32_t length) {
    const uint64_t in[3] = {endpoint, length, g_bulk_timeout_ms};
    return IOConnectCallMethod(*(uint32_t *)context, SEL_BULK_OUT, in, 3, (length > 0) ? data : NULL, length,
                               NULL, NULL, NULL, NULL);
}

static int ios_bulk_in(void *context, uint8_t endpoint, void *data, uint32_t length, uint32_t *transferred) {
    const uint64_t in[3] = {endpoint, length, g_bulk_timeout_ms};
    uint64_t out[1] = {0};
    uint32_t out_count = 1;
    size_t size = length;
    kern_return_t kr = IOConnectCallMethod(*(uint32_t *)context, SEL_BULK_IN, in, 3, NULL, 0, out, &out_count, data, &size);
    *transferred = (uint32_t)out[0];
    return kr;
}

void ugen_driver_make_transport(uint32_t *connection, ugen_transport *transport) {
    transport->context = connection;
    transport->control_out = ios_control_out;
    transport->control_in = ios_control_in;
    transport->bulk_out = ios_bulk_out;
    transport->bulk_in = ios_bulk_in;
}

#endif
