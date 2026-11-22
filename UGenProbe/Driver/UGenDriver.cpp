// USB pipe driver for the ASUS UGen300 (Hailo-10H). It attaches to the device in either mode, selects
// configuration 1, opens interface 0, and forwards control and bulk transfers for its user client.
#include <os/log.h>
#include <string.h>

#include <DriverKit/IOLib.h>
#include <DriverKit/IOUserClient.h>
#include <DriverKit/IOBufferMemoryDescriptor.h>
#include <DriverKit/OSCollections.h>
#include <USBDriverKit/IOUSBHostDevice.h>
#include <USBDriverKit/IOUSBHostInterface.h>
#include <USBDriverKit/IOUSBHostPipe.h>
#include <USBDriverKit/USBDriverKitDefs.h>

#include "UGenDriver.h"
#include "UGenShared.h"

#define LOG(fmt, ...) os_log(OS_LOG_DEFAULT, "UGenDriver: " fmt, ##__VA_ARGS__)

static const uint32_t kControlTimeoutMs = 10000;
static const uint32_t kBulkTimeoutMs = 60000;
static const uint8_t kLoaderConfigurationCount = 2;
static const int kPipeSlots = 4;

struct UGenDriver_IVars
{
    IOUSBHostDevice * device;
    IOUSBHostInterface * interface;
    bool deviceOpen;
    bool interfaceOpen;
    uint8_t pipeAddress[kPipeSlots];
    IOUSBHostPipe * pipe[kPipeSlots];
    IOBufferMemoryDescriptor * outBuffer;
    IOBufferMemoryDescriptor * inBuffer;
    uint8_t * outBytes;
    uint8_t * inBytes;
    UGenDriverInfo info;
};

bool UGenDriver::init()
{
    if (!super::init()) {
        return false;
    }
    ivars = IONewZero(UGenDriver_IVars, 1);
    return ivars != nullptr;
}

void UGenDriver::free()
{
    IOSafeDeleteNULL(ivars, UGenDriver_IVars, 1);
    super::free();
}

static kern_return_t CreateBuffer(IOUSBHostDevice * device, uint64_t direction, uint32_t capacity,
                                  IOBufferMemoryDescriptor ** buffer, uint8_t ** bytes)
{
    kern_return_t ret = device->CreateIOBuffer(direction, capacity, buffer);
    if (ret != kIOReturnSuccess) {
        return ret;
    }
    (*buffer)->SetLength(capacity);
    IOAddressSegment segment = {};
    ret = (*buffer)->GetAddressRange(&segment);
    if (ret != kIOReturnSuccess) {
        OSSafeReleaseNULL(*buffer);
        return ret;
    }
    *bytes = reinterpret_cast<uint8_t *>(segment.address);
    return kIOReturnSuccess;
}

// Selects configuration 1 and opens interface 0. Used at attach and again by Reset().
static bool ConfigureInterface(UGenDriver * self, UGenDriver_IVars * ivars, uint32_t interfaceIndex, bool reconfigure)
{
    UGenDriverInfo & info = ivars->info;
    IOUSBHostDevice * device = ivars->device;

    // When re-configuring (Reset), drop to "unconfigured" first. Asking for the configuration that is
    // already selected may not reach the device at all, and the device only forgets its old sessions
    // when it sees its configuration change.
    if (reconfigure) {
        kern_return_t unconfigure = device->SetConfiguration(0, false);
        LOG("SetConfiguration(0) -> 0x%08x", unconfigure);
    }
    // matchInterfaces = false: this driver owns the interfaces itself.
    info.setConfigStatus = device->SetConfiguration(1, false);
    LOG("SetConfiguration(1) -> 0x%08x", info.setConfigStatus);
    if (info.setConfigStatus != kIOReturnSuccess) {
        return false;
    }

    uintptr_t iterator = 0;
    info.interfaceStatus = device->CreateInterfaceIterator(&iterator);
    if (info.interfaceStatus != kIOReturnSuccess) {
        LOG("CreateInterfaceIterator -> 0x%08x", info.interfaceStatus);
        return false;
    }
    // Interfaces come back in order; skip to the one asked for.
    for (uint32_t i = 0; i <= interfaceIndex; i++) {
        OSSafeReleaseNULL(ivars->interface);
        info.interfaceStatus = device->CopyInterface(iterator, &ivars->interface);
        if (info.interfaceStatus != kIOReturnSuccess || ivars->interface == nullptr) {
            break;
        }
    }
    device->DestroyInterfaceIterator(iterator);
    if (info.interfaceStatus == kIOReturnSuccess && ivars->interface == nullptr) {
        info.interfaceStatus = kIOReturnNotFound;
    }
    if (info.interfaceStatus != kIOReturnSuccess) {
        LOG("CopyInterface -> 0x%08x", info.interfaceStatus);
        return false;
    }
    info.interfaceStatus = ivars->interface->Open(self, 0, nullptr);
    LOG("interface Open -> 0x%08x", info.interfaceStatus);
    if (info.interfaceStatus != kIOReturnSuccess) {
        return false;
    }
    ivars->interfaceOpen = true;

    return true;
}

// Opens the device, selects configuration 1 and opens interface 0. Records each step in ivars->info.
static void Bringup(UGenDriver * self, UGenDriver_IVars * ivars)
{
    UGenDriverInfo & info = ivars->info;
    memset(&info, 0, sizeof(info));
    info.structVersion = 2;
    info.maxBulkChunk = UGEN_MAX_BULK_CHUNK;
    info.openStatus = info.descriptorStatus = info.setConfigStatus = UGEN_STATUS_NOT_RUN;
    info.interfaceStatus = info.bufferStatus = UGEN_STATUS_NOT_RUN;

    IOUSBHostDevice * device = ivars->device;
    if (device == nullptr) {
        LOG("provider is not an IOUSBHostDevice");
        return;
    }

    info.openStatus = device->Open(self, 0, 0);
    LOG("device Open -> 0x%08x", info.openStatus);
    if (info.openStatus != kIOReturnSuccess) {
        return;
    }
    ivars->deviceOpen = true;

    const IOUSBDeviceDescriptor * descriptor = device->CopyDeviceDescriptor();
    if (descriptor == nullptr) {
        info.descriptorStatus = kIOReturnNotFound;
        return;
    }
    info.descriptorStatus = kIOReturnSuccess;
    info.idVendor = descriptor->idVendor;
    info.idProduct = descriptor->idProduct;
    info.bcdDevice = descriptor->bcdDevice;
    info.deviceClass = descriptor->bDeviceClass;
    info.numConfigurations = descriptor->bNumConfigurations;
    IOUSBHostFreeDescriptor(descriptor);
    // Both modes use device class 0xFF; the loader is the one with two configurations.
    info.mode = (info.numConfigurations == kLoaderConfigurationCount) ? UGEN_MODE_LOADER : UGEN_MODE_RUNTIME;
    LOG("descriptor bcdDevice=0x%04x configs=%u mode=%u", info.bcdDevice, info.numConfigurations, info.mode);

    if (!ConfigureInterface(self, ivars, 0, false)) {
        return;
    }

    // A buffer created with kIOMemoryDirectionOut is mapped read-only in the driver, so the buffers the
    // driver fills itself must be InOut.
    info.bufferStatus = CreateBuffer(device, kIOMemoryDirectionInOut, UGEN_MAX_BULK_CHUNK, &ivars->outBuffer, &ivars->outBytes);
    if (info.bufferStatus == kIOReturnSuccess) {
        info.bufferStatus = CreateBuffer(device, kIOMemoryDirectionIn, UGEN_MAX_BULK_CHUNK, &ivars->inBuffer, &ivars->inBytes);
    }
    LOG("buffers -> 0x%08x", info.bufferStatus);
    if (info.bufferStatus != kIOReturnSuccess) {
        return;
    }
    info.ready = 1;
}

static IOUSBHostPipe * PipeFor(UGenDriver_IVars * ivars, uint8_t endpoint, kern_return_t * status)
{
    int freeSlot = -1;
    for (int i = 0; i < kPipeSlots; i++) {
        if (ivars->pipe[i] != nullptr && ivars->pipeAddress[i] == endpoint) {
            *status = kIOReturnSuccess;
            return ivars->pipe[i];
        }
        if (ivars->pipe[i] == nullptr && freeSlot < 0) {
            freeSlot = i;
        }
    }
    if (freeSlot < 0) {
        *status = kIOReturnNoResources;
        return nullptr;
    }
    IOUSBHostPipe * pipe = nullptr;
    *status = ivars->interface->CopyPipe(endpoint, &pipe);
    if (*status != kIOReturnSuccess || pipe == nullptr) {
        LOG("CopyPipe(0x%02x) -> 0x%08x", endpoint, *status);
        if (*status == kIOReturnSuccess) {
            *status = kIOReturnNotFound;
        }
        return nullptr;
    }
    // Start every pipe from a clean state on both ends (clears a halt and resets the data sequence),
    // as the Mac transport does when it opens the interface. Without this, replies on a session that
    // follows another one on the same interface can go missing.
    kern_return_t cleared = pipe->ClearStall(true);
    if (cleared != kIOReturnSuccess) {
        LOG("ClearStall(0x%02x) -> 0x%08x", endpoint, cleared);
    }
    ivars->pipe[freeSlot] = pipe;
    ivars->pipeAddress[freeSlot] = endpoint;
    return pipe;
}

static void ReleaseInterface(UGenDriver * self, UGenDriver_IVars * ivars)
{
    for (int i = 0; i < kPipeSlots; i++) {
        OSSafeReleaseNULL(ivars->pipe[i]);
        ivars->pipeAddress[i] = 0;
    }
    if (ivars->interface != nullptr) {
        if (ivars->interfaceOpen) {
            ivars->interface->Close(self, 0);
            ivars->interfaceOpen = false;
        }
        OSSafeReleaseNULL(ivars->interface);
    }
}

kern_return_t UGenDriver::Reset(uint32_t interfaceIndex)
{
    if (!ivars->deviceOpen) {
        return kIOReturnNotOpen;
    }
    const bool hadBuffers = (ivars->outBuffer != nullptr) && (ivars->inBuffer != nullptr);
    ivars->info.ready = 0;
    ReleaseInterface(this, ivars);
    if (!ConfigureInterface(this, ivars, interfaceIndex, true)) {
        LOG("Reset failed: config 0x%08x interface 0x%08x", ivars->info.setConfigStatus, ivars->info.interfaceStatus);
        return (ivars->info.setConfigStatus != kIOReturnSuccess) ? ivars->info.setConfigStatus : ivars->info.interfaceStatus;
    }
    ivars->info.ready = hadBuffers ? 1 : 0;
    LOG("Reset done, ready=%u", ivars->info.ready);
    return hadBuffers ? kIOReturnSuccess : kIOReturnNoMemory;
}

void UGenDriver::CopyInfo(void * out, uint32_t size)
{
    const uint32_t count = (size < sizeof(ivars->info)) ? size : static_cast<uint32_t>(sizeof(ivars->info));
    memcpy(out, &ivars->info, count);
}

kern_return_t UGenDriver::ControlTransfer(uint8_t requestType, uint8_t request, uint16_t value, uint16_t index,
                                          void * data, uint16_t length, uint16_t * transferred)
{
    *transferred = 0;
    if (!ivars->deviceOpen) {
        return kIOReturnNotOpen;
    }
    if (length > UGEN_MAX_CONTROL_DATA) {
        return kIOReturnBadArgument;
    }
    const bool deviceToHost = (requestType & 0x80) != 0;

    IOBufferMemoryDescriptor * buffer = nullptr;
    uint8_t * bytes = nullptr;
    if (length > 0) {
        kern_return_t ret = CreateBuffer(ivars->device, deviceToHost ? kIOMemoryDirectionIn : kIOMemoryDirectionInOut,
                                         length, &buffer, &bytes);
        if (ret != kIOReturnSuccess) {
            return ret;
        }
        if (!deviceToHost) {
            memcpy(bytes, data, length);
        }
    }

    kern_return_t ret = ivars->device->DeviceRequest(this, requestType, request, value, index, length, buffer,
                                                     transferred, kControlTimeoutMs);
    if (ret == kIOReturnSuccess && deviceToHost && length > 0) {
        memcpy(data, bytes, (*transferred < length) ? *transferred : length);
    }
    OSSafeReleaseNULL(buffer);
    return ret;
}

kern_return_t UGenDriver::BulkOut(uint8_t endpoint, const void * data, uint32_t length, uint32_t timeoutMs)
{
    if (!ivars->info.ready) {
        return kIOReturnNotReady;
    }
    if (length > UGEN_MAX_BULK_CHUNK || (endpoint & 0x80) != 0) {
        return kIOReturnBadArgument;
    }
    kern_return_t status = kIOReturnSuccess;
    IOUSBHostPipe * pipe = PipeFor(ivars, endpoint, &status);
    if (pipe == nullptr) {
        return status;
    }
    if (length > 0) {
        memcpy(ivars->outBytes, data, length);
    }
    uint32_t transferred = 0;
    status = pipe->IO(ivars->outBuffer, length, &transferred, (timeoutMs != 0) ? timeoutMs : kBulkTimeoutMs);
    if (status == kIOReturnSuccess && transferred != length) {
        status = kIOReturnUnderrun;
    }
    return status;
}

kern_return_t UGenDriver::BulkIn(uint8_t endpoint, uint32_t length, uint32_t timeoutMs, const void ** data, uint32_t * transferred)
{
    *transferred = 0;
    *data = nullptr;
    if (!ivars->info.ready) {
        return kIOReturnNotReady;
    }
    if (length == 0 || length > UGEN_MAX_BULK_CHUNK || (endpoint & 0x80) == 0) {
        return kIOReturnBadArgument;
    }
    kern_return_t status = kIOReturnSuccess;
    IOUSBHostPipe * pipe = PipeFor(ivars, endpoint, &status);
    if (pipe == nullptr) {
        return status;
    }
    status = pipe->IO(ivars->inBuffer, length, transferred, (timeoutMs != 0) ? timeoutMs : kBulkTimeoutMs);
    if (status == kIOReturnSuccess) {
        *data = ivars->inBytes;
    }
    return status;
}

kern_return_t IMPL(UGenDriver, Start)
{
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) {
        LOG("super Start failed 0x%08x", ret);
        return ret;
    }
    LOG("Start: matched provider");

    ivars->device = OSDynamicCast(IOUSBHostDevice, provider);
    if (ivars->device != nullptr) {
        ivars->device->retain();
    }
    Bringup(this, ivars);

    // Register even after a failed bring-up so the client can read the failure point.
    ret = RegisterService();
    LOG("RegisterService -> 0x%08x, ready=%u", ret, ivars->info.ready);
    return kIOReturnSuccess;
}

kern_return_t IMPL(UGenDriver, Stop)
{
    LOG("Stop");
    ivars->info.ready = 0;
    ReleaseInterface(this, ivars);
    OSSafeReleaseNULL(ivars->outBuffer);
    OSSafeReleaseNULL(ivars->inBuffer);
    if (ivars->device != nullptr) {
        if (ivars->deviceOpen) {
            ivars->device->Close(this, 0);
            ivars->deviceOpen = false;
        }
        OSSafeReleaseNULL(ivars->device);
    }
    return Stop(provider, SUPERDISPATCH);
}

kern_return_t IMPL(UGenDriver, NewUserClient)
{
    IOService * client = nullptr;
    kern_return_t ret = Create(this, "UserClientProperties", &client);
    if (ret != kIOReturnSuccess) {
        LOG("NewUserClient: Create failed 0x%08x", ret);
        return ret;
    }
    *userClient = OSDynamicCast(IOUserClient, client);
    if (*userClient == nullptr) {
        client->release();
        return kIOReturnError;
    }
    return kIOReturnSuccess;
}
