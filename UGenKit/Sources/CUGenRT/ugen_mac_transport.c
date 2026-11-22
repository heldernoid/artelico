// macOS implementation of the driver API in ugen_ios_transport.h. On the Mac there is no driver
// extension: this file opens the UGen300 through IOKit and does what UGenDriver does on iPadOS
// (select configuration 1, open interface 0, forward control and bulk transfers).
#include "ugen_ios_transport.h"

#include <TargetConditionals.h>

#if TARGET_OS_OSX || TARGET_OS_MACCATALYST

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <string.h>

#define VENDOR_ID 0x0B05
#define PRODUCT_ID 0x1D6F
#define NO_DATA_TIMEOUT_MS 60000u
#define COMPLETION_TIMEOUT_MS 60000u

static uint32_t g_bulk_timeout_ms = COMPLETION_TIMEOUT_MS;

void ugen_driver_set_bulk_timeout(uint32_t milliseconds) {
    g_bulk_timeout_ms = (milliseconds != 0) ? milliseconds : COMPLETION_TIMEOUT_MS;
}
#define LOADER_CONFIGURATION_COUNT 2
#define MAX_PIPES 8

// One device at a time, like the driver. `connection` handed to callers is always 1.
static struct {
    IOUSBDeviceInterface **device;
    IOUSBInterfaceInterface **interface;
    uint8_t pipe_address[MAX_PIPES];
    uint8_t pipe_ref[MAX_PIPES];
    uint8_t pipe_count;
    ugen_driver_info info;
} g_usb;

static void mac_close(void) {
    if (g_usb.interface) {
        (*g_usb.interface)->USBInterfaceClose(g_usb.interface);
        (*g_usb.interface)->Release(g_usb.interface);
    }
    if (g_usb.device) {
        (*g_usb.device)->USBDeviceClose(g_usb.device);
        (*g_usb.device)->Release(g_usb.device);
    }
    memset(&g_usb, 0, sizeof g_usb);
}

static uint8_t pipe_for(uint8_t endpoint) {
    for (uint8_t i = 0; i < g_usb.pipe_count; i++) {
        if (g_usb.pipe_address[i] == endpoint) return g_usb.pipe_ref[i];
    }
    return 0;
}

static int open_interface(uint32_t *connection, uint8_t wanted_interface) {
    *connection = 0;
    mac_close();

    CFMutableDictionaryRef match = IOServiceMatching(kIOUSBDeviceClassName);
    int vid = VENDOR_ID, pid = PRODUCT_ID;
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberIntType, &vid);
    CFDictionarySetValue(match, CFSTR(kUSBVendorID), number);
    CFRelease(number);
    number = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    CFDictionarySetValue(match, CFSTR(kUSBProductID), number);
    CFRelease(number);
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, match);
    if (service == IO_OBJECT_NULL) return UGEN_DRIVER_NOT_FOUND;

    IOCFPlugInInterface **plug = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(service, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score);
    IOObjectRelease(service);
    if (kr != kIOReturnSuccess || plug == NULL) return (kr != kIOReturnSuccess) ? kr : kIOReturnError;
    (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&g_usb.device);
    (*plug)->Release(plug);
    if (g_usb.device == NULL) return kIOReturnError;

    ugen_driver_info *info = &g_usb.info;
    info->struct_version = 2;
    info->max_bulk_chunk = 1024 * 1024;
    info->open_status = (*g_usb.device)->USBDeviceOpen(g_usb.device);
    if (info->open_status != kIOReturnSuccess) {
        kr = info->open_status;
        (*g_usb.device)->Release(g_usb.device);
        g_usb.device = NULL;
        return kr;
    }
    UInt16 value16 = 0;
    UInt8 value8 = 0;
    (*g_usb.device)->GetDeviceVendor(g_usb.device, &value16); info->id_vendor = value16;
    (*g_usb.device)->GetDeviceProduct(g_usb.device, &value16); info->id_product = value16;
    (*g_usb.device)->GetDeviceReleaseNumber(g_usb.device, &value16); info->bcd_device = value16;
    (*g_usb.device)->GetDeviceClass(g_usb.device, &value8); info->device_class = value8;
    (*g_usb.device)->GetNumberOfConfigurations(g_usb.device, &value8); info->num_configurations = value8;
    info->mode = (info->num_configurations == LOADER_CONFIGURATION_COUNT) ? 1 : 2;

    info->set_config_status = (*g_usb.device)->SetConfiguration(g_usb.device, 1);
    if (info->set_config_status != kIOReturnSuccess) { *connection = 1; return 0; }

    IOUSBFindInterfaceRequest request = {kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare,
                                         kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare};
    io_iterator_t iterator = IO_OBJECT_NULL;
    info->interface_status = (*g_usb.device)->CreateInterfaceIterator(g_usb.device, &request, &iterator);
    if (info->interface_status != kIOReturnSuccess) { *connection = 1; return 0; }
    io_service_t candidate;
    while (g_usb.interface == NULL && (candidate = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        plug = NULL;
        kr = IOCreatePlugInInterfaceForService(candidate, kIOUSBInterfaceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score);
        IOObjectRelease(candidate);
        if (kr != kIOReturnSuccess || plug == NULL) continue;
        IOUSBInterfaceInterface **interface = NULL;
        (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID), (LPVOID *)&interface);
        (*plug)->Release(plug);
        if (interface == NULL) continue;
        UInt8 interface_number = 0xFF;
        (*interface)->GetInterfaceNumber(interface, &interface_number);
        if (interface_number == wanted_interface) g_usb.interface = interface; else (*interface)->Release(interface);
    }
    IOObjectRelease(iterator);
    if (g_usb.interface == NULL) { info->interface_status = kIOReturnNotFound; *connection = 1; return 0; }

    info->interface_status = (*g_usb.interface)->USBInterfaceOpen(g_usb.interface);
    if (info->interface_status != kIOReturnSuccess) {
        (*g_usb.interface)->Release(g_usb.interface);
        g_usb.interface = NULL;
        *connection = 1;
        return 0;
    }
    UInt8 endpoint_count = 0;
    (*g_usb.interface)->GetNumEndpoints(g_usb.interface, &endpoint_count);
    for (UInt8 pipe = 1; pipe <= endpoint_count && g_usb.pipe_count < MAX_PIPES; pipe++) {
        UInt8 direction, endpoint_number, type, interval;
        UInt16 max_packet;
        if ((*g_usb.interface)->GetPipeProperties(g_usb.interface, pipe, &direction, &endpoint_number, &type, &max_packet, &interval) != kIOReturnSuccess) continue;
        if (type != kUSBBulk) continue;
        g_usb.pipe_address[g_usb.pipe_count] = (uint8_t)(endpoint_number | (direction == kUSBIn ? 0x80 : 0));
        g_usb.pipe_ref[g_usb.pipe_count] = pipe;
        g_usb.pipe_count++;
        (*g_usb.interface)->ClearPipeStallBothEnds(g_usb.interface, pipe);
    }
    info->buffer_status = kIOReturnSuccess;
    info->ready = 1;
    *connection = 1;
    return 0;
}

int ugen_driver_open(uint32_t *connection) {
    return open_interface(connection, 0);
}

void ugen_driver_close(uint32_t connection) {
    if (connection != 0) mac_close();
}

int ugen_driver_reset(uint32_t *connection, uint8_t interface_number) {
    // Reopening the device selects configuration 1 again and opens the interface asked for.
    return open_interface(connection, interface_number);
}

int ugen_driver_get_info(uint32_t connection, ugen_driver_info *info) {
    if (connection == 0 || g_usb.device == NULL) return kIOReturnNotOpen;
    *info = g_usb.info;
    return 0;
}

static int mac_control_out(void *context, uint8_t type, uint8_t request, uint16_t value, uint16_t index,
                           const void *data, uint16_t length) {
    (void)context;
    if (g_usb.device == NULL) return kIOReturnNotOpen;
    IOUSBDevRequestTO r = {.bmRequestType = type, .bRequest = request, .wValue = value, .wIndex = index,
                           .wLength = length, .pData = (void *)data,
                           .noDataTimeout = NO_DATA_TIMEOUT_MS, .completionTimeout = COMPLETION_TIMEOUT_MS};
    return (*g_usb.device)->DeviceRequestTO(g_usb.device, &r);
}

static int mac_control_in(void *context, uint8_t type, uint8_t request, uint16_t value, uint16_t index,
                          void *data, uint16_t length, uint16_t *transferred) {
    (void)context;
    *transferred = 0;
    if (g_usb.device == NULL) return kIOReturnNotOpen;
    IOUSBDevRequestTO r = {.bmRequestType = type, .bRequest = request, .wValue = value, .wIndex = index,
                           .wLength = length, .pData = data,
                           .noDataTimeout = NO_DATA_TIMEOUT_MS, .completionTimeout = COMPLETION_TIMEOUT_MS};
    kern_return_t kr = (*g_usb.device)->DeviceRequestTO(g_usb.device, &r);
    *transferred = (uint16_t)r.wLenDone;
    return kr;
}

static int mac_bulk_out(void *context, uint8_t endpoint, const void *data, uint32_t length) {
    (void)context;
    const uint8_t pipe = pipe_for(endpoint);
    if (g_usb.interface == NULL || pipe == 0) return kIOReturnNotOpen;
    return (*g_usb.interface)->WritePipeTO(g_usb.interface, pipe, (void *)data, length, g_bulk_timeout_ms, g_bulk_timeout_ms);
}

static int mac_bulk_in(void *context, uint8_t endpoint, void *data, uint32_t length, uint32_t *transferred) {
    (void)context;
    *transferred = 0;
    const uint8_t pipe = pipe_for(endpoint);
    if (g_usb.interface == NULL || pipe == 0) return kIOReturnNotOpen;
    UInt32 size = length;
    kern_return_t kr = (*g_usb.interface)->ReadPipeTO(g_usb.interface, pipe, data, &size, g_bulk_timeout_ms, g_bulk_timeout_ms);
    *transferred = size;
    return kr;
}

void ugen_driver_make_transport(uint32_t *connection, ugen_transport *transport) {
    transport->context = connection;
    transport->control_out = mac_control_out;
    transport->control_in = mac_control_in;
    transport->bulk_out = mac_bulk_out;
    transport->bulk_in = mac_bulk_in;
}

#endif
