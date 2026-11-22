// Read-only probe of the UGen300 loader: three vendor IN control requests on EP0
// (protocol version, SKU, build string). With --configure it first opens the device and selects
// configuration 1 (what a Linux host does automatically on plug-in; undone by replugging). Never writes data.
// Build: clang -o loaderprobe loaderprobe.c -framework IOKit -framework CoreFoundation
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdio.h>

static kern_return_t vendor_in(IOUSBDeviceInterface **dev, UInt8 req, UInt16 wValue, UInt8 *buf, UInt16 len, UInt32 *got) {
    IOUSBDevRequest r = { .bmRequestType = 0xC0, .bRequest = req, .wValue = wValue, .wIndex = 0, .wLength = len, .pData = buf };
    kern_return_t kr = (*dev)->DeviceRequest(dev, &r);
    *got = r.wLenDone;
    return kr;
}

int main(int argc, char **argv) {
    int configure = argc > 1 && !strcmp(argv[1], "--configure");
    CFMutableDictionaryRef match = IOServiceMatching(kIOUSBDeviceClassName);
    int vid = 0x0B05, pid = 0x1D6F;
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &vid);
    CFDictionarySetValue(match, CFSTR(kUSBVendorID), n); CFRelease(n);
    n = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    CFDictionarySetValue(match, CFSTR(kUSBProductID), n); CFRelease(n);
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, match);
    if (!svc) { printf("device not found\n"); return 2; }
    IOCFPlugInInterface **plug = NULL; SInt32 score;
    kern_return_t kr = IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score);
    IOObjectRelease(svc);
    if (kr || !plug) { printf("plugin failed 0x%08x\n", kr); return 1; }
    IOUSBDeviceInterface **dev = NULL;
    (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&dev);
    (*plug)->Release(plug);

    UInt8 buf[64]; UInt32 got; UInt8 cur = 0xff;
    if (configure) {
        kr = (*dev)->USBDeviceOpen(dev);
        printf("USBDeviceOpen: 0x%08x\n", kr);
        if (kr == kIOReturnSuccess) {
            kr = (*dev)->SetConfiguration(dev, 1);
            printf("SetConfiguration(1): 0x%08x\n", kr);
        }
    }
    (*dev)->GetConfiguration(dev, &cur);
    printf("current configuration: %u\n", cur);
    memset(buf, 0, sizeof buf);
    kr = vendor_in(dev, 0x16, 0, buf, 4, &got);
    printf("0x16 protocol version: kr=0x%08x len=%u value=%u\n", kr, got, buf[0] | buf[1] << 8 | buf[2] << 16 | (unsigned)buf[3] << 24);
    memset(buf, 0, sizeof buf);
    kr = vendor_in(dev, 0x14, 0, buf, 64, &got);
    printf("0x14 SKU:              kr=0x%08x len=%u value=\"%.64s\"\n", kr, got, buf);
    memset(buf, 0, sizeof buf);
    kr = vendor_in(dev, 0x11, 0, buf, 64, &got);
    printf("0x11 build:            kr=0x%08x len=%u value=\"%.64s\"\n", kr, got, buf);
    if (configure) (*dev)->USBDeviceClose(dev);
    (*dev)->Release(dev);
    return 0;
}
