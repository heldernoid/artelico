#include <os/log.h>
#include <string.h>

#include <DriverKit/IOLib.h>
#include <DriverKit/IOMemoryDescriptor.h>
#include <DriverKit/IOMemoryMap.h>
#include <DriverKit/IOUserClient.h>
#include <DriverKit/OSCollections.h>

#include "UGenDriver.h"
#include "UGenUserClient.h"
#include "UGenShared.h"

#define LOG(fmt, ...) os_log(OS_LOG_DEFAULT, "UGenUserClient: " fmt, ##__VA_ARGS__)

struct UGenUserClient_IVars
{
    UGenDriver * driver;
};

bool UGenUserClient::init()
{
    if (!super::init()) {
        return false;
    }
    ivars = IONewZero(UGenUserClient_IVars, 1);
    return ivars != nullptr;
}

void UGenUserClient::free()
{
    IOSafeDeleteNULL(ivars, UGenUserClient_IVars, 1);
    super::free();
}

kern_return_t IMPL(UGenUserClient, Start)
{
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) {
        return ret;
    }
    ivars->driver = OSDynamicCast(UGenDriver, provider);
    if (ivars->driver == nullptr) {
        LOG("provider is not UGenDriver");
        return kIOReturnBadArgument;
    }
    ivars->driver->retain();
    return kIOReturnSuccess;
}

kern_return_t IMPL(UGenUserClient, Stop)
{
    OSSafeReleaseNULL(ivars->driver);
    return Stop(provider, SUPERDISPATCH);
}

// Structure input arrives inline (OSData) up to 4096 bytes and as a memory descriptor above that.
// Calls `body` with a pointer to the bytes, whichever way they came.
template <typename Body>
static kern_return_t WithStructureInput(IOUserClientMethodArguments * arguments, uint32_t expectedLength, Body body)
{
    if (expectedLength == 0) {
        return body(static_cast<const void *>(nullptr));
    }
    if (arguments->structureInput != nullptr) {
        if (arguments->structureInput->getLength() < expectedLength) {
            return kIOReturnBadArgument;
        }
        return body(arguments->structureInput->getBytesNoCopy());
    }
    if (arguments->structureInputDescriptor != nullptr) {
        IOMemoryMap * map = nullptr;
        kern_return_t ret = arguments->structureInputDescriptor->CreateMapping(kIOMemoryMapReadOnly, 0, 0, 0, 0, &map);
        if (ret != kIOReturnSuccess || map == nullptr) {
            return (ret != kIOReturnSuccess) ? ret : kIOReturnNoMemory;
        }
        if (map->GetLength() < expectedLength) {
            ret = kIOReturnBadArgument;
        } else {
            ret = body(reinterpret_cast<const void *>(map->GetAddress()));
        }
        OSSafeReleaseNULL(map);
        return ret;
    }
    return kIOReturnBadArgument;
}

// Returns `length` bytes to the caller, inline or through the caller's output descriptor.
static kern_return_t SetStructureOutput(IOUserClientMethodArguments * arguments, const void * data, uint32_t length)
{
    if (arguments->structureOutputDescriptor != nullptr) {
        if (length == 0) {
            return kIOReturnSuccess;
        }
        IOMemoryMap * map = nullptr;
        kern_return_t ret = arguments->structureOutputDescriptor->CreateMapping(0, 0, 0, 0, 0, &map);
        if (ret != kIOReturnSuccess || map == nullptr) {
            return (ret != kIOReturnSuccess) ? ret : kIOReturnNoMemory;
        }
        if (map->GetLength() < length) {
            ret = kIOReturnNoSpace;
        } else {
            memcpy(reinterpret_cast<void *>(map->GetAddress()), data, length);
        }
        OSSafeReleaseNULL(map);
        return ret;
    }
    if (length > arguments->structureOutputMaximumSize) {
        return kIOReturnNoSpace;
    }
    arguments->structureOutput = OSData::withBytes(data, length);
    return (arguments->structureOutput != nullptr) ? kIOReturnSuccess : kIOReturnNoMemory;
}

kern_return_t UGenUserClient::ExternalMethod(uint64_t selector,
                                             IOUserClientMethodArguments * arguments,
                                             const IOUserClientMethodDispatch * dispatch,
                                             OSObject * target,
                                             void * reference)
{
    UGenDriver * driver = ivars->driver;
    if (driver == nullptr || arguments == nullptr) {
        return kIOReturnNotReady;
    }
    const uint64_t * in = arguments->scalarInput;
    const uint32_t inCount = arguments->scalarInputCount;

    switch (selector) {
    case UGEN_SELECTOR_GET_INFO: {
        UGenDriverInfo info = {};
        driver->CopyInfo(&info, sizeof(info));
        return SetStructureOutput(arguments, &info, sizeof(info));
    }

    case UGEN_SELECTOR_CONTROL_IN: {
        if (inCount < 5 || in[4] > UGEN_MAX_CONTROL_DATA || arguments->scalarOutput == nullptr || arguments->scalarOutputCount < 1) {
            return kIOReturnBadArgument;
        }
        uint8_t data[UGEN_MAX_CONTROL_DATA];
        uint16_t transferred = 0;
        kern_return_t ret = driver->ControlTransfer(static_cast<uint8_t>(in[0]) | 0x80, static_cast<uint8_t>(in[1]),
                                                    static_cast<uint16_t>(in[2]), static_cast<uint16_t>(in[3]),
                                                    data, static_cast<uint16_t>(in[4]), &transferred);
        if (ret != kIOReturnSuccess) {
            return ret;
        }
        arguments->scalarOutput[0] = transferred;
        arguments->scalarOutputCount = 1;
        return SetStructureOutput(arguments, data, transferred);
    }

    case UGEN_SELECTOR_CONTROL_OUT: {
        if (inCount < 4) {
            return kIOReturnBadArgument;
        }
        const uint32_t length = (arguments->structureInput != nullptr)
            ? static_cast<uint32_t>(arguments->structureInput->getLength()) : 0;
        if (length > UGEN_MAX_CONTROL_DATA) {
            return kIOReturnBadArgument;
        }
        uint8_t data[UGEN_MAX_CONTROL_DATA];
        if (length > 0) {
            memcpy(data, arguments->structureInput->getBytesNoCopy(), length);
        }
        uint16_t transferred = 0;
        return driver->ControlTransfer(static_cast<uint8_t>(in[0]) & 0x7F, static_cast<uint8_t>(in[1]),
                                       static_cast<uint16_t>(in[2]), static_cast<uint16_t>(in[3]),
                                       data, static_cast<uint16_t>(length), &transferred);
    }

    case UGEN_SELECTOR_BULK_OUT: {
        if (inCount < 2 || in[1] > UGEN_MAX_BULK_CHUNK) {
            return kIOReturnBadArgument;
        }
        const uint8_t endpoint = static_cast<uint8_t>(in[0]);
        const uint32_t length = static_cast<uint32_t>(in[1]);
        const uint32_t timeoutMs = (inCount >= 3) ? static_cast<uint32_t>(in[2]) : 0;
        return WithStructureInput(arguments, length, [driver, endpoint, length, timeoutMs](const void * bytes) {
            return driver->BulkOut(endpoint, bytes, length, timeoutMs);
        });
    }

    case UGEN_SELECTOR_BULK_IN: {
        if (inCount < 2 || in[1] == 0 || in[1] > UGEN_MAX_BULK_CHUNK || arguments->scalarOutput == nullptr || arguments->scalarOutputCount < 1) {
            return kIOReturnBadArgument;
        }
        const void * data = nullptr;
        uint32_t transferred = 0;
        const uint32_t timeoutMs = (inCount >= 3) ? static_cast<uint32_t>(in[2]) : 0;
        kern_return_t ret = driver->BulkIn(static_cast<uint8_t>(in[0]), static_cast<uint32_t>(in[1]), timeoutMs, &data, &transferred);
        if (ret != kIOReturnSuccess) {
            return ret;
        }
        arguments->scalarOutput[0] = transferred;
        arguments->scalarOutputCount = 1;
        return SetStructureOutput(arguments, data, transferred);
    }

    case UGEN_SELECTOR_RESET:
        return driver->Reset((inCount >= 1 && in[0] < 8) ? static_cast<uint32_t>(in[0]) : 0);

    default:
        return kIOReturnUnsupported;
    }
}
