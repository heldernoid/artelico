// Uploads the HailoRT runtime root filesystem to a UGen300 that is in loader mode.
// The image goes to the stick's RAM only; a power cycle returns it to the loader.
// Sequence follows vendor/ref-ugen300-loader/PROTOCOL.md (third-party, from USB captures).
//
// Build: clang -O2 -o ugenload ugenload.c -framework IOKit -framework CoreFoundation
// Usage: ./ugenload <core-image-hailo-hailo10-usb-dongle.ext4>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define VID 0x0B05
#define PID 0x1D6F
#define EXPECTED_PROTOCOL 1u
#define EXPECTED_BUILD "Hailo Linux build v1.10.10"
#define LOADER_PRODUCT "UGen300 USB Loader"
#define RUNTIME_PRODUCT "UGen300 USB AI Accelerator (Hailo-10H)"
#define CHUNK_SIZE 65536u
#define TIMEOUT_MS 10000u

enum { REQ_BUILD = 0x11, REQ_START = 0x12, REQ_SKU = 0x14, REQ_STATUS = 0x15, REQ_PROTOCOL = 0x16 };

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static void sleep_ms(unsigned ms) { usleep(ms * 1000); }

static io_service_t find_device(void) {
    CFMutableDictionaryRef match = IOServiceMatching(kIOUSBDeviceClassName);
    int vid = VID, pid = PID;
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &vid);
    CFDictionarySetValue(match, CFSTR(kUSBVendorID), n);
    CFRelease(n);
    n = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    CFDictionarySetValue(match, CFSTR(kUSBProductID), n);
    CFRelease(n);
    return IOServiceGetMatchingService(kIOMainPortDefault, match);
}

static int product_name(io_service_t service, char *out, size_t size) {
    out[0] = 0;
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, CFSTR("USB Product Name"), kCFAllocatorDefault, 0);
    if (!value) return 0;
    int ok = CFGetTypeID(value) == CFStringGetTypeID() &&
             CFStringGetCString((CFStringRef)value, out, (CFIndex)size, kCFStringEncodingUTF8);
    CFRelease(value);
    return ok;
}

static kern_return_t vendor_in(IOUSBDeviceInterface **dev, UInt8 request, UInt16 wValue, void *buf, UInt16 len, UInt32 *got) {
    IOUSBDevRequestTO r = {.bmRequestType = 0xC0, .bRequest = request, .wValue = wValue, .wIndex = 0, .wLength = len,
                           .pData = buf, .noDataTimeout = TIMEOUT_MS, .completionTimeout = TIMEOUT_MS};
    kern_return_t kr = (*dev)->DeviceRequestTO(dev, &r);
    if (got) *got = r.wLenDone;
    return kr;
}

static kern_return_t vendor_out(IOUSBDeviceInterface **dev, UInt8 request, UInt16 wValue, UInt16 wIndex) {
    IOUSBDevRequestTO r = {.bmRequestType = 0x40, .bRequest = request, .wValue = wValue, .wIndex = wIndex, .wLength = 0,
                           .pData = NULL, .noDataTimeout = TIMEOUT_MS, .completionTimeout = TIMEOUT_MS};
    return (*dev)->DeviceRequestTO(dev, &r);
}

// Selects configuration 1, opens interface 0 and finds the bulk OUT pipe.
static IOUSBInterfaceInterface **claim_interface(IOUSBDeviceInterface **dev, UInt8 *bulk_out_pipe) {
    kern_return_t kr = (*dev)->SetConfiguration(dev, 1);
    if (kr != kIOReturnSuccess) { fprintf(stderr, "SetConfiguration(1) failed: 0x%08x\n", kr); return NULL; }

    IOUSBFindInterfaceRequest req = {kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare,
                                     kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare};
    io_iterator_t it = IO_OBJECT_NULL;
    kr = (*dev)->CreateInterfaceIterator(dev, &req, &it);
    if (kr != kIOReturnSuccess) { fprintf(stderr, "CreateInterfaceIterator failed: 0x%08x\n", kr); return NULL; }
    io_service_t service = IOIteratorNext(it);
    IOObjectRelease(it);
    if (!service) { fprintf(stderr, "no interface after SetConfiguration(1)\n"); return NULL; }

    IOCFPlugInInterface **plug = NULL;
    SInt32 score = 0;
    kr = IOCreatePlugInInterfaceForService(service, kIOUSBInterfaceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score);
    IOObjectRelease(service);
    if (kr != kIOReturnSuccess || !plug) { fprintf(stderr, "interface plugin failed: 0x%08x\n", kr); return NULL; }
    IOUSBInterfaceInterface **intf = NULL;
    (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID), (LPVOID *)&intf);
    (*plug)->Release(plug);
    if (!intf) { fprintf(stderr, "no interface object\n"); return NULL; }

    kr = (*intf)->USBInterfaceOpen(intf);
    if (kr != kIOReturnSuccess) {
        fprintf(stderr, "USBInterfaceOpen failed: 0x%08x\n", kr);
        (*intf)->Release(intf);
        return NULL;
    }

    UInt8 count = 0;
    (*intf)->GetNumEndpoints(intf, &count);
    *bulk_out_pipe = 0;
    for (UInt8 pipe = 1; pipe <= count; pipe++) {
        UInt8 direction, number, type, interval;
        UInt16 max_packet;
        if ((*intf)->GetPipeProperties(intf, pipe, &direction, &number, &type, &max_packet, &interval) != kIOReturnSuccess) continue;
        if (direction == kUSBOut && type == kUSBBulk) {
            *bulk_out_pipe = pipe;
            printf("bulk OUT endpoint 0x%02x, max packet %u\n", number, max_packet);
        }
    }
    if (!*bulk_out_pipe) {
        fprintf(stderr, "bulk OUT endpoint not found\n");
        (*intf)->USBInterfaceClose(intf);
        (*intf)->Release(intf);
        return NULL;
    }
    return intf;
}

static void release_interface(IOUSBInterfaceInterface **intf) {
    if (!intf) return;
    (*intf)->USBInterfaceClose(intf);
    (*intf)->Release(intf);
}

static int wait_for_runtime(double timeout_s) {
    double deadline = now_s() + timeout_s;
    while (now_s() < deadline) {
        io_service_t service = find_device();
        if (service) {
            char name[128];
            product_name(service, name, sizeof name);
            IOObjectRelease(service);
            if (strcmp(name, RUNTIME_PRODUCT) == 0) return 1;
        }
        sleep_ms(250);
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: %s <rootfs.ext4>\n", argv[0]); return 64; }

    int fd = open(argv[1], O_RDONLY);
    struct stat st;
    if (fd < 0 || fstat(fd, &st) != 0) { perror(argv[1]); return 66; }
    if (st.st_size <= 0 || st.st_size > 0xFFFFFFFFLL) { fprintf(stderr, "image size out of range\n"); return 65; }
    const UInt32 image_size = (UInt32)st.st_size;

    io_service_t service = find_device();
    if (!service) { fprintf(stderr, "UGen300 not found on this Mac's USB bus\n"); return 2; }
    char name[128];
    product_name(service, name, sizeof name);
    printf("found \"%s\"\n", name);
    if (strcmp(name, RUNTIME_PRODUCT) == 0) { printf("already in runtime mode; nothing to do\n"); return 0; }
    if (strcmp(name, LOADER_PRODUCT) != 0) { fprintf(stderr, "unexpected product string; refusing to upload\n"); return 3; }

    IOCFPlugInInterface **plug = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(service, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score);
    IOObjectRelease(service);
    if (kr != kIOReturnSuccess || !plug) { fprintf(stderr, "device plugin failed: 0x%08x\n", kr); return 1; }
    IOUSBDeviceInterface **dev = NULL;
    (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&dev);
    (*plug)->Release(plug);
    if (!dev) return 1;

    int rc = 1;
    IOUSBInterfaceInterface **intf = NULL;
    UInt8 pipe = 0;
    kr = (*dev)->USBDeviceOpen(dev);
    if (kr != kIOReturnSuccess) { fprintf(stderr, "USBDeviceOpen failed: 0x%08x\n", kr); goto done_no_close; }

    intf = claim_interface(dev, &pipe);
    if (!intf) goto done;

    // Identify and validate the loader before sending anything.
    UInt8 raw[64];
    UInt32 got = 0;
    memset(raw, 0, sizeof raw);
    kr = vendor_in(dev, REQ_PROTOCOL, 0, raw, 4, &got);
    UInt32 protocol = raw[0] | raw[1] << 8 | raw[2] << 16 | (UInt32)raw[3] << 24;
    if (kr != kIOReturnSuccess || got != 4 || protocol != EXPECTED_PROTOCOL) {
        fprintf(stderr, "loader protocol check failed (kr=0x%08x len=%u value=%u, expected %u)\n", kr, got, protocol, EXPECTED_PROTOCOL);
        goto done;
    }
    char sku[65] = {0}, build[65] = {0};
    vendor_in(dev, REQ_SKU, 0, sku, 64, &got);
    kr = vendor_in(dev, REQ_BUILD, 0, build, 64, &got);
    printf("loader protocol %u, SKU \"%s\", build \"%s\"\n", protocol, sku, build);
    if (kr != kIOReturnSuccess || strcmp(build, EXPECTED_BUILD) != 0) {
        fprintf(stderr, "build string is not \"%s\"; this image is for that loader only. Refusing.\n", EXPECTED_BUILD);
        goto done;
    }

    // The vendor tool releases and re-claims the interface here.
    release_interface(intf);
    intf = claim_interface(dev, &pipe);
    if (!intf) goto done;

    kr = vendor_out(dev, REQ_START, (UInt16)(image_size & 0xFFFF), (UInt16)(image_size >> 16));
    if (kr != kIOReturnSuccess) { fprintf(stderr, "upload start failed: 0x%08x\n", kr); goto done; }
    printf("upload start sent for %u bytes\n", image_size);

    UInt8 ready = 0;
    for (int i = 0; i < 100 && ready != 1; i++) {
        kr = vendor_in(dev, REQ_STATUS, 0, &ready, 1, &got);
        if (kr != kIOReturnSuccess) { fprintf(stderr, "receiver-ready poll failed: 0x%08x\n", kr); goto done; }
        if (ready != 1) sleep_ms(100);
    }
    if (ready != 1) { fprintf(stderr, "receiver never became ready\n"); goto done; }

    UInt8 ping[64];
    memset(ping, 0xAA, sizeof ping);
    UInt32 counter = 0;
    kr = (*intf)->WritePipeTO(intf, pipe, ping, sizeof ping, TIMEOUT_MS, TIMEOUT_MS);
    if (kr != kIOReturnSuccess) { fprintf(stderr, "first ping failed: 0x%08x\n", kr); goto done; }
    vendor_in(dev, REQ_STATUS, 1, &counter, 4, &got);
    sleep_ms(100);
    kr = (*intf)->WritePipeTO(intf, pipe, ping, sizeof ping, TIMEOUT_MS, TIMEOUT_MS);
    if (kr != kIOReturnSuccess) { fprintf(stderr, "second ping failed: 0x%08x\n", kr); goto done; }
    counter = 0;
    vendor_in(dev, REQ_STATUS, 1, &counter, 4, &got);
    printf("ping byte counter: %u (expected 64)\n", counter);

    UInt8 data_ready = 0;
    kr = vendor_in(dev, REQ_STATUS, 2, &data_ready, 1, &got);
    if (kr != kIOReturnSuccess || data_ready != 1) {
        fprintf(stderr, "loader not ready for image data (kr=0x%08x value=%u)\n", kr, data_ready);
        goto done;
    }

    UInt8 *chunk = malloc(CHUNK_SIZE);
    if (!chunk) goto done;
    UInt32 sent = 0;
    const double start = now_s();
    while (sent < image_size) {
        ssize_t n = read(fd, chunk, CHUNK_SIZE);
        if (n <= 0) { fprintf(stderr, "read failed at offset %u\n", sent); free(chunk); goto done; }
        kr = (*intf)->WritePipeTO(intf, pipe, chunk, (UInt32)n, TIMEOUT_MS, TIMEOUT_MS);
        if (kr != kIOReturnSuccess) { fprintf(stderr, "bulk write failed at offset %u: 0x%08x\n", sent, kr); free(chunk); goto done; }
        sent += (UInt32)n;
    }
    free(chunk);
    kr = (*intf)->WritePipeTO(intf, pipe, ping, 0, TIMEOUT_MS, TIMEOUT_MS);  // zero-length transfer ends the image
    const double elapsed = now_s() - start;
    printf("sent %u bytes in %.2f s (%.1f MB/s); end marker kr=0x%08x\n", sent, elapsed, sent / 1e6 / elapsed, kr);
    if (kr != kIOReturnSuccess) goto done;

    rc = 0;
done:
    release_interface(intf);
    (*dev)->USBDeviceClose(dev);
done_no_close:
    (*dev)->Release(dev);
    close(fd);
    if (rc != 0) return rc;

    printf("waiting for the runtime to enumerate...\n");
    const double wait_start = now_s();
    if (!wait_for_runtime(30.0)) { fprintf(stderr, "runtime did not appear within 30 s\n"); return 4; }
    printf("runtime is up after %.1f s: \"%s\"\n", now_s() - wait_start, RUNTIME_PRODUCT);
    return 0;
}
