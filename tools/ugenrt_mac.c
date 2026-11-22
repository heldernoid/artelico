// Mac command-line client for a UGen300 in runtime mode, built on the portable ugenrt core with an
// IOKit USB transport. Used to validate the protocol port before moving it to the iPad.
//
// Build:
//   clang -O2 -Wall -I ../UGenKit/Sources/CUGenRT/include -o ugenrt ugenrt_mac.c \
//     ../UGenKit/Sources/CUGenRT/ugenrt.c -framework IOKit -framework CoreFoundation
// Usage:
//   ./ugenrt identify
//   ./ugenrt infer <model.hef> <input.raw> <output_size_bytes> <output.bin> [iterations]
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "ugenrt.h"

#define VID 0x0B05
#define PID 0x1D6F
#define RUNTIME_PRODUCT "UGen300 USB AI Accelerator (Hailo-10H)"
#define NO_DATA_TIMEOUT_MS 60000u
#define COMPLETION_TIMEOUT_MS 60000u

typedef struct {
    IOUSBDeviceInterface **device;
    IOUSBInterfaceInterface **interface;
    UInt8 pipe_in;
    UInt8 pipe_out;
} mac_usb;

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1e3 + (double)ts.tv_nsec / 1e6;
}

static int mac_control_out(void *context, uint8_t type, uint8_t request, uint16_t value, uint16_t index,
                           const void *data, uint16_t length) {
    mac_usb *usb = context;
    IOUSBDevRequestTO r = {.bmRequestType = type, .bRequest = request, .wValue = value, .wIndex = index,
                           .wLength = length, .pData = (void *)data,
                           .noDataTimeout = NO_DATA_TIMEOUT_MS, .completionTimeout = COMPLETION_TIMEOUT_MS};
    return (*usb->device)->DeviceRequestTO(usb->device, &r);
}

static int mac_control_in(void *context, uint8_t type, uint8_t request, uint16_t value, uint16_t index,
                          void *data, uint16_t length, uint16_t *transferred) {
    mac_usb *usb = context;
    IOUSBDevRequestTO r = {.bmRequestType = type, .bRequest = request, .wValue = value, .wIndex = index,
                           .wLength = length, .pData = data,
                           .noDataTimeout = NO_DATA_TIMEOUT_MS, .completionTimeout = COMPLETION_TIMEOUT_MS};
    kern_return_t kr = (*usb->device)->DeviceRequestTO(usb->device, &r);
    *transferred = (uint16_t)r.wLenDone;
    return kr;
}

static int mac_bulk_out(void *context, uint8_t endpoint, const void *data, uint32_t length) {
    (void)endpoint;  // the interface was chosen at open time
    mac_usb *usb = context;
    return (*usb->interface)->WritePipeTO(usb->interface, usb->pipe_out, (void *)data, length,
                                          NO_DATA_TIMEOUT_MS, COMPLETION_TIMEOUT_MS);
}

static int mac_bulk_in(void *context, uint8_t endpoint, void *data, uint32_t length, uint32_t *transferred) {
    (void)endpoint;
    mac_usb *usb = context;
    UInt32 size = length;
    kern_return_t kr = (*usb->interface)->ReadPipeTO(usb->interface, usb->pipe_in, data, &size,
                                                     NO_DATA_TIMEOUT_MS, COMPLETION_TIMEOUT_MS);
    *transferred = size;
    return kr;
}

static void mac_close(mac_usb *usb) {
    if (usb->interface) {
        (*usb->interface)->USBInterfaceClose(usb->interface);
        (*usb->interface)->Release(usb->interface);
    }
    if (usb->device) {
        (*usb->device)->USBDeviceClose(usb->device);
        (*usb->device)->Release(usb->device);
    }
    memset(usb, 0, sizeof *usb);
}

static int mac_open(mac_usb *usb, UInt8 interface_number) {
    memset(usb, 0, sizeof *usb);
    CFMutableDictionaryRef match = IOServiceMatching(kIOUSBDeviceClassName);
    int vid = VID, pid = PID;
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &vid);
    CFDictionarySetValue(match, CFSTR(kUSBVendorID), n);
    CFRelease(n);
    n = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    CFDictionarySetValue(match, CFSTR(kUSBProductID), n);
    CFRelease(n);
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, match);
    if (!service) { fprintf(stderr, "UGen300 not found\n"); return -1; }

    char name[128] = {0};
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, CFSTR("USB Product Name"), kCFAllocatorDefault, 0);
    if (value) {
        if (CFGetTypeID(value) == CFStringGetTypeID())
            CFStringGetCString((CFStringRef)value, name, sizeof name, kCFStringEncodingUTF8);
        CFRelease(value);
    }
    if (strcmp(name, RUNTIME_PRODUCT) != 0) {
        fprintf(stderr, "device is \"%s\", not in runtime mode; run ugenload first\n", name);
        IOObjectRelease(service);
        return -1;
    }

    IOCFPlugInInterface **plug = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(service, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score);
    IOObjectRelease(service);
    if (kr != kIOReturnSuccess || !plug) { fprintf(stderr, "device plugin failed: 0x%08x\n", kr); return -1; }
    (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&usb->device);
    (*plug)->Release(plug);
    if (!usb->device) return -1;

    kr = (*usb->device)->USBDeviceOpen(usb->device);
    if (kr != kIOReturnSuccess) {
        fprintf(stderr, "USBDeviceOpen failed: 0x%08x\n", kr);
        (*usb->device)->Release(usb->device);
        usb->device = NULL;
        return -1;
    }
    UInt8 configuration = 0;
    (*usb->device)->GetConfiguration(usb->device, &configuration);
    if (configuration == 0) {
        kr = (*usb->device)->SetConfiguration(usb->device, 1);
        if (kr != kIOReturnSuccess) { fprintf(stderr, "SetConfiguration(1) failed: 0x%08x\n", kr); mac_close(usb); return -1; }
    }

    IOUSBFindInterfaceRequest req = {kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare,
                                     kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare};
    io_iterator_t it = IO_OBJECT_NULL;
    kr = (*usb->device)->CreateInterfaceIterator(usb->device, &req, &it);
    if (kr != kIOReturnSuccess) { fprintf(stderr, "CreateInterfaceIterator failed: 0x%08x\n", kr); mac_close(usb); return -1; }
    io_service_t candidate;
    while (!usb->interface && (candidate = IOIteratorNext(it))) {
        plug = NULL;
        kr = IOCreatePlugInInterfaceForService(candidate, kIOUSBInterfaceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score);
        IOObjectRelease(candidate);
        if (kr != kIOReturnSuccess || !plug) continue;
        IOUSBInterfaceInterface **intf = NULL;
        (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID), (LPVOID *)&intf);
        (*plug)->Release(plug);
        if (!intf) continue;
        UInt8 number = 0xFF;
        (*intf)->GetInterfaceNumber(intf, &number);
        if (number == interface_number) usb->interface = intf; else (*intf)->Release(intf);
    }
    IOObjectRelease(it);
    if (!usb->interface) { fprintf(stderr, "interface %u not found\n", interface_number); mac_close(usb); return -1; }

    kr = (*usb->interface)->USBInterfaceOpen(usb->interface);
    if (kr != kIOReturnSuccess) {
        fprintf(stderr, "USBInterfaceOpen failed: 0x%08x\n", kr);
        (*usb->interface)->Release(usb->interface);
        usb->interface = NULL;
        mac_close(usb);
        return -1;
    }
    UInt8 count = 0;
    (*usb->interface)->GetNumEndpoints(usb->interface, &count);
    for (UInt8 pipe = 1; pipe <= count; pipe++) {
        UInt8 direction, number, type, interval;
        UInt16 max_packet;
        if ((*usb->interface)->GetPipeProperties(usb->interface, pipe, &direction, &number, &type, &max_packet, &interval) != kIOReturnSuccess) continue;
        if (type != kUSBBulk) continue;
        if (direction == kUSBIn) usb->pipe_in = pipe;
        if (direction == kUSBOut) usb->pipe_out = pipe;
    }
    if (!usb->pipe_in || !usb->pipe_out) { fprintf(stderr, "bulk endpoints not found\n"); mac_close(usb); return -1; }
    // Clear anything left over from an earlier session, as HailoRT does.
    (*usb->interface)->ClearPipeStallBothEnds(usb->interface, usb->pipe_out);
    (*usb->interface)->ClearPipeStallBothEnds(usb->interface, usb->pipe_in);
    return 0;
}

static void *read_file(const char *path, uint32_t *size) {
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); return NULL; }
    fseek(f, 0, SEEK_END);
    long length = ftell(f);
    fseek(f, 0, SEEK_SET);
    void *data = malloc((size_t)length);
    if (!data || fread(data, 1, (size_t)length, f) != (size_t)length) { fclose(f); free(data); return NULL; }
    fclose(f);
    *size = (uint32_t)length;
    return data;
}

static int report(const char *step, int rc, const ugen_session *session) {
    if (rc == UGEN_OK) return 0;
    if (rc == UGEN_ERR_TRANSPORT) fprintf(stderr, "%s: USB transfer failed, IOKit 0x%08x\n", step, session->last_transport_error);
    else if (rc >= 0x10000) fprintf(stderr, "%s: client error 0x%x\n", step, rc);
    else fprintf(stderr, "%s: device returned hailo_status %d\n", step, rc);
    return 1;
}

static int cmd_identify(ugen_session *session) {
    uint32_t device = 0;
    if (report("device create", ugen_device_create(session, &device), session)) return 1;
    ugen_identity id;
    if (report("identify", ugen_device_identify(session, device, &id), session)) return 1;
    printf("Firmware Version: %u.%u.%u (%s)\n", id.fw_major, id.fw_minor, id.fw_revision, id.is_release ? "release" : "develop");
    printf("Protocol Version: %u, Logger Version: %u\n", id.protocol_version, id.logger_version);
    printf("Board Name: %s\nProduct Name: %s\nSerial Number: %s\nPart Number: %s\n", id.board_name, id.product_name, id.serial_number, id.part_number);
    printf("Device Architecture: %u (6 = HAILO10H)\n", id.device_architecture);
    float ts0 = 0, ts1 = 0;
    if (ugen_device_chip_temperature(session, device, &ts0, &ts1) == UGEN_OK) printf("Chip temperature: %.1f C / %.1f C\n", ts0, ts1);
    ugen_device_destroy(session, device);
    return 0;
}

static int cmd_infer(ugen_session *session, int argc, char **argv) {
    if (argc < 6) { fprintf(stderr, "usage: infer <model.hef> <input.raw> <output_size> <output.bin> [iterations]\n"); return 64; }
    uint32_t hef_size = 0, input_size = 0;
    void *hef = read_file(argv[2], &hef_size);
    void *input = read_file(argv[3], &input_size);
    const uint32_t output_size = (uint32_t)strtoul(argv[4], NULL, 0);
    const int iterations = (argc > 6) ? atoi(argv[6]) : 1;
    void *output = calloc(1, output_size);
    if (!hef || !input || !output) return 66;

    uint32_t vdevice = 0, model = 0, configured = 0, queue = 0;
    double t = now_ms();
    if (report("vdevice create", ugen_vdevice_create(session, &vdevice), session)) return 1;
    printf("vdevice handle %u (%.1f ms)\n", vdevice, now_ms() - t);

    t = now_ms();
    if (report("create infer model", ugen_infer_model_create(session, vdevice, hef, hef_size, &model), session)) return 1;
    printf("infer model handle %u, HEF %u bytes uploaded (%.1f ms)\n", model, hef_size, now_ms() - t);

    // No stream parameters: the device keeps the HEF's default formats and NMS settings.
    t = now_ms();
    if (report("configure", ugen_configure(session, model, vdevice, NULL, 0, NULL, 0, &configured, &queue), session)) return 1;
    printf("configured handle %u, async queue size %u (%.1f ms)\n", configured, queue, now_ms() - t);

    const ugen_const_buffer inputs[1] = {{input, input_size}};
    const ugen_buffer outputs[1] = {{output, output_size}};
    double total = 0, best = 1e9, worst = 0;
    int rc = UGEN_OK;
    for (int i = 0; i < iterations; i++) {
        t = now_ms();
        rc = ugen_infer(session, configured, model, inputs, 1, outputs, 1);
        const double elapsed = now_ms() - t;
        if (report("infer", rc, session)) break;
        if (i == 0) printf("first inference: %.2f ms\n", elapsed);
        else { total += elapsed; if (elapsed < best) best = elapsed; if (elapsed > worst) worst = elapsed; }
    }
    if (rc == UGEN_OK) {
        if (iterations > 1) {
            const double mean = total / (iterations - 1);
            printf("%d further inferences: mean %.2f ms, min %.2f ms, max %.2f ms, %.1f FPS (sequential)\n",
                   iterations - 1, mean, best, worst, 1000.0 / mean);
        }
        FILE *f = fopen(argv[5], "wb");
        if (f) { fwrite(output, 1, output_size, f); fclose(f); printf("wrote %u output bytes to %s\n", output_size, argv[5]); }
    }

    ugen_configured_destroy(session, configured);
    ugen_infer_model_destroy(session, model);
    ugen_vdevice_destroy(session, vdevice);
    free(hef); free(input); free(output);
    return rc == UGEN_OK ? 0 : 1;
}

// Generic run: any number of inputs and outputs. Outputs given with a name are requested as float32.
//   run <model.hef> <outdir> <iterations> in:<size>[:<file>]... out:<size>[:<stream name>]...
static int cmd_run(ugen_session *session, int argc, char **argv) {
    if (argc < 6) { fprintf(stderr, "usage: run <model.hef> <outdir> <iterations> in:<size>[:file] ... out:<size>[:name] ...\n"); return 64; }
    uint32_t hef_size = 0;
    void *hef = read_file(argv[2], &hef_size);
    if (!hef) return 66;
    const char *outdir = argv[3];
    const int iterations = atoi(argv[4]);

    ugen_const_buffer inputs[8];
    ugen_buffer outputs[32];
    ugen_stream_params output_params[32];
    uint32_t input_count = 0, output_count = 0, param_count = 0;
    for (int i = 5; i < argc; i++) {
        char *arg = argv[i];
        if (strncmp(arg, "in:", 3) == 0 && input_count < 8) {
            char *end = NULL;
            uint32_t size = (uint32_t)strtoul(arg + 3, &end, 0);
            void *data = calloc(1, size);
            if (*end == ':') {
                uint32_t file_size = 0;
                void *file = read_file(end + 1, &file_size);
                if (!file || file_size != size) { fprintf(stderr, "input file %s is not %u bytes\n", end + 1, size); return 66; }
                memcpy(data, file, size);
                free(file);
            } else {
                memset(data, 114, size);  // mid-grey frame
            }
            inputs[input_count++] = (ugen_const_buffer){data, size};
        } else if (strncmp(arg, "out:", 4) == 0 && output_count < 32) {
            char *end = NULL;
            uint32_t size = (uint32_t)strtoul(arg + 4, &end, 0);
            outputs[output_count++] = (ugen_buffer){calloc(1, size), size};
            if (*end == ':') {
                output_params[param_count++] = (ugen_stream_params){
                    .name = end + 1, .format_order = UGEN_FORMAT_ORDER_AUTO, .format_type = UGEN_FORMAT_TYPE_FLOAT32,
                    .nms_score_threshold = -1.0f, .nms_iou_threshold = -1.0f, .nms_max_proposals_per_class = 0xFFFFFFFFu,
                    .nms_max_accumulated_mask_size = 0xFFFFFFFFu, .nms_max_proposals_total = 0xFFFFFFFFu};
            }
        }
    }

    uint32_t vdevice = 0, model = 0, configured = 0, queue = 0;
    if (report("vdevice create", ugen_vdevice_create(session, &vdevice), session)) return 1;
    double t = now_ms();
    int rc = ugen_infer_model_create(session, vdevice, hef, hef_size, &model);
    if (report("create infer model", rc, session)) { ugen_vdevice_destroy(session, vdevice); return 1; }
    const double load_ms = now_ms() - t;
    t = now_ms();
    rc = ugen_configure(session, model, vdevice, NULL, 0, output_params, param_count, &configured, &queue);
    if (report("configure", rc, session)) { ugen_infer_model_destroy(session, model); ugen_vdevice_destroy(session, vdevice); return 1; }
    const double configure_ms = now_ms() - t;

    double total = 0;
    for (int i = 0; i < iterations && rc == UGEN_OK; i++) {
        t = now_ms();
        rc = ugen_infer(session, configured, model, inputs, input_count, outputs, output_count);
        if (i > 0 || iterations == 1) total += now_ms() - t;
    }
    if (report("infer", rc, session) == 0) {
        const double mean = total / ((iterations > 1) ? iterations - 1 : 1);
        printf("OK load %.0f ms, configure %.0f ms, queue %u, mean %.2f ms (%.1f FPS sequential)\n",
               load_ms, configure_ms, queue, mean, 1000.0 / mean);
        for (uint32_t i = 0; i < output_count; i++) {
            char path[1024];
            snprintf(path, sizeof path, "%s/out%u.bin", outdir, i);
            FILE *f = fopen(path, "wb");
            if (f) { fwrite(outputs[i].data, 1, outputs[i].size, f); fclose(f); }
        }
    }
    ugen_configured_destroy(session, configured);
    ugen_infer_model_destroy(session, model);
    ugen_vdevice_destroy(session, vdevice);
    return rc == UGEN_OK ? 0 : 1;
}

// Pipelined benchmark with one input and one output: keeps `depth` frames in flight.
//   bench <model.hef> <input.raw> <output_size> <depth> <frames>
static int cmd_bench(ugen_session *session, int argc, char **argv) {
    if (argc < 7) { fprintf(stderr, "usage: bench <model.hef> <input.raw> <output_size> <depth> <frames>\n"); return 64; }
    uint32_t hef_size = 0, input_size = 0;
    void *hef = read_file(argv[2], &hef_size);
    void *input = read_file(argv[3], &input_size);
    const uint32_t output_size = (uint32_t)strtoul(argv[4], NULL, 0);
    const int depth = atoi(argv[5]);
    const int frames = atoi(argv[6]);
    void *output = calloc(1, output_size);
    if (!hef || !input || !output || depth < 1 || depth > 32) return 66;

    uint32_t vdevice = 0, model = 0, configured = 0, queue = 0;
    if (report("vdevice create", ugen_vdevice_create(session, &vdevice), session)) return 1;
    if (report("create infer model", ugen_infer_model_create(session, vdevice, hef, hef_size, &model), session)) return 1;
    if (report("configure", ugen_configure(session, model, vdevice, NULL, 0, NULL, 0, &configured, &queue), session)) return 1;

    const ugen_const_buffer inputs[1] = {{input, input_size}};
    const ugen_buffer outputs[1] = {{output, output_size}};
    uint32_t ids[32];
    int submitted = 0, collected = 0, rc = UGEN_OK;
    const double start = now_ms();
    while (collected < frames && rc == UGEN_OK) {
        while (submitted < frames && submitted - collected < depth && rc == UGEN_OK) {
            rc = ugen_infer_submit(session, configured, model, inputs, 1, &output_size, 1, &ids[submitted % 32]);
            submitted++;
        }
        if (rc != UGEN_OK) break;
        rc = ugen_infer_collect(session, ids[collected % 32], outputs, 1);
        collected++;
    }
    const double elapsed = now_ms() - start;
    if (report("bench", rc, session) == 0)
        printf("depth %d: %d frames in %.0f ms = %.1f FPS\n", depth, frames, elapsed, frames * 1000.0 / elapsed);
    ugen_configured_destroy(session, configured);
    ugen_infer_model_destroy(session, model);
    ugen_vdevice_destroy(session, vdevice);
    return rc == UGEN_OK ? 0 : 1;
}

// Tries the CONNECT handshake for other services on interface 1, to see which servers the runtime runs.
static int cmd_ports(void) {
    static const uint32_t ports[] = {UGEN_SERVER_PORT, UGEN_LLM_PORT, UGEN_VLM_PORT, UGEN_SPEECH_TO_TEXT_PORT, 12345};
    mac_usb usb;
    if (mac_open(&usb, 1) != 0) return 2;
    ugen_transport transport = {&usb, mac_control_out, mac_control_in, mac_bulk_out, mac_bulk_in};
    for (unsigned i = 0; i < sizeof ports / sizeof ports[0]; i++) {
        ugen_session session;
        int rc = ugen_session_open_port(&session, &transport, 1, ports[i]);
        printf("port %u: %s (%d)\n", ports[i], rc == UGEN_OK ? "accepted" : "refused", rc);
        if (rc == UGEN_OK) ugen_session_close(&session);
    }
    mac_close(&usb);
    return 0;
}

int main(int argc, char **argv) {
    if (argc >= 2 && strcmp(argv[1], "ports") == 0) return cmd_ports();
    if (argc < 2) { fprintf(stderr, "usage: %s identify | infer ...\n", argv[0]); return 64; }
    mac_usb usb;
    if (mac_open(&usb, 0) != 0) return 2;

    ugen_transport transport = {&usb, mac_control_out, mac_control_in, mac_bulk_out, mac_bulk_in};
    ugen_session session;
    int rc = ugen_session_open(&session, &transport, 0);
    if (report("connect", rc, &session)) { mac_close(&usb); return 3; }

    int result = 64;
    if (strcmp(argv[1], "identify") == 0) result = cmd_identify(&session);
    else if (strcmp(argv[1], "infer") == 0) result = cmd_infer(&session, argc, argv);
    else if (strcmp(argv[1], "run") == 0) result = cmd_run(&session, argc, argv);
    else if (strcmp(argv[1], "bench") == 0) result = cmd_bench(&session, argc, argv);
    else fprintf(stderr, "unknown command %s\n", argv[1]);

    report("close", ugen_session_close(&session), &session);
    mac_close(&usb);
    return result;
}
