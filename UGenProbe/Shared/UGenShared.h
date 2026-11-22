// Shared between the DriverKit extension and its clients (plain C).
// The driver is a thin USB pipe: it opens the UGen300, selects configuration 1, opens interface 0 and
// forwards control and bulk transfers. All protocol logic lives in the client (CUGenRT).
#ifndef UGenShared_h
#define UGenShared_h
#include <stdint.h>

#define UGEN_VENDOR_ID  0x0B05
#define UGEN_PRODUCT_ID 0x1D6F

#define UGEN_DRIVER_SERVICE_NAME "UGenDriver"

// User-client selectors.
enum {
    // structure out: UGenDriverInfo
    UGEN_SELECTOR_GET_INFO = 0,
    // scalars in: bmRequestType, bRequest, wValue, wIndex, wLength. structure out: data. scalar out: bytes transferred
    UGEN_SELECTOR_CONTROL_IN = 1,
    // scalars in: bmRequestType, bRequest, wValue, wIndex. structure in: data (optional)
    UGEN_SELECTOR_CONTROL_OUT = 2,
    // scalars in: endpoint address, length, [timeout ms; 0 or absent = default]. structure in: data
    // (omitted when length is 0, which sends a zero-length packet)
    UGEN_SELECTOR_BULK_OUT = 3,
    // scalars in: endpoint address, max length, [timeout ms; 0 or absent = default]. structure out: data.
    // scalar out: bytes transferred
    UGEN_SELECTOR_BULK_IN = 4,
    // scalar in (optional): interface number, default 0. Drops the pipes, selects configuration 1 again and
    // opens that interface. The runtime has five interfaces; a client that died leaves its interface unusable
    // until the stick restarts, so the next client moves to another one.
    UGEN_SELECTOR_RESET = 5,
};

#define UGEN_MAX_CONTROL_DATA 4096u
#define UGEN_MAX_BULK_CHUNK (1024u * 1024u)

#define UGEN_STATUS_NOT_RUN ((int32_t)0x7FFFFFFF)

enum {
    UGEN_MODE_UNKNOWN = 0,
    UGEN_MODE_LOADER = 1,   // "UGen300 USB Loader": two configurations, waits for the runtime image
    UGEN_MODE_RUNTIME = 2,  // "UGen300 USB AI Accelerator (Hailo-10H)": one configuration, HailoRT gadget
};

typedef struct {
    uint32_t structVersion;
    uint32_t mode;
    uint32_t ready;  // 1 when the device is configured and interface 0 is open
    int32_t openStatus;
    int32_t descriptorStatus;
    int32_t setConfigStatus;
    int32_t interfaceStatus;
    int32_t bufferStatus;
    uint16_t idVendor;
    uint16_t idProduct;
    uint16_t bcdDevice;
    uint8_t deviceClass;
    uint8_t numConfigurations;
    uint32_t maxBulkChunk;
} UGenDriverInfo;

#endif
