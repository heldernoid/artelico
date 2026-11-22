// Read-only USB descriptor dump for the UGen300 (VID 0x0B05 / PID 0x1D6F).
// Only issues GET_DESCRIPTOR requests; never opens the device or sets a configuration.
// Build: clang -o usbdump usbdump.c -framework IOKit -framework CoreFoundation
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdio.h>

#define VID 0x0B05
#define PID 0x1D6F

static void print_string(IOUSBDeviceInterface **dev, UInt8 idx, const char *label) {
    if (!idx) return;
    UInt8 buf[256] = {0};
    IOUSBDevRequest req = {
        .bmRequestType = USBmakebmRequestType(kUSBIn, kUSBStandard, kUSBDevice),
        .bRequest = kUSBRqGetDescriptor,
        .wValue = (kUSBStringDesc << 8) | idx,
        .wIndex = 0x0409,
        .wLength = sizeof(buf),
        .pData = buf,
    };
    kern_return_t kr = (*dev)->DeviceRequest(dev, &req);
    if (kr != kIOReturnSuccess) { printf("  %s[%u]: <error 0x%08x>\n", label, idx, kr); return; }
    printf("  %s[%u]: \"", label, idx);
    for (int i = 2; i + 1 < buf[0]; i += 2) putchar(buf[i]);
    printf("\"\n");
}

static void dump_config(IOUSBDeviceInterface **dev, const UInt8 *p, int total) {
    int off = 0;
    while (off + 2 <= total) {
        UInt8 len = p[off], type = p[off + 1];
        if (len < 2 || off + len > total) break;
        const UInt8 *d = p + off;
        switch (type) {
        case 0x02:
            printf("CONFIG value=%u numInterfaces=%u attrs=0x%02x maxPower=%u (units; x8mA at SS, x2mA at HS) totalLen=%u iConfig=%u\n",
                   d[5], d[4], d[7], d[8], d[2] | (d[3] << 8), d[6]);
            print_string(dev, d[6], "iConfiguration");
            break;
        case 0x04:
            printf("  INTERFACE num=%u alt=%u numEP=%u class=0x%02x sub=0x%02x proto=0x%02x iInterface=%u\n",
                   d[2], d[3], d[4], d[5], d[6], d[7], d[8]);
            print_string(dev, d[8], "  iInterface");
            break;
        case 0x05: {
            static const char *tt[] = {"control", "isoc", "bulk", "interrupt"};
            printf("    ENDPOINT addr=0x%02x (%s) type=%s maxPacket=%u interval=%u\n",
                   d[2], (d[2] & 0x80) ? "IN" : "OUT", tt[d[3] & 3], d[4] | (d[5] << 8), d[6]);
            break;
        }
        case 0x30:
            printf("      SS_COMPANION maxBurst=%u attrs=0x%02x bytesPerInterval=%u\n", d[2], d[3], d[4] | (d[5] << 8));
            break;
        default:
            printf("  DESC type=0x%02x len=%u:", type, len);
            for (int i = 0; i < len; i++) printf(" %02x", d[i]);
            printf("\n");
        }
        off += len;
    }
    printf("  raw:");
    for (int i = 0; i < total; i++) printf(" %02x", p[i]);
    printf("\n");
}

int main(void) {
    CFMutableDictionaryRef match = IOServiceMatching(kIOUSBDeviceClassName);
    int vid = VID, pid = PID;
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &vid);
    CFDictionarySetValue(match, CFSTR(kUSBVendorID), n); CFRelease(n);
    n = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    CFDictionarySetValue(match, CFSTR(kUSBProductID), n); CFRelease(n);

    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, match, &it) != KERN_SUCCESS) return 1;
    io_service_t svc;
    int found = 0;
    while ((svc = IOIteratorNext(it))) {
        found++;
        IOCFPlugInInterface **plug = NULL; SInt32 score;
        kern_return_t kr = IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID,
                                                             kIOCFPlugInInterfaceID, &plug, &score);
        IOObjectRelease(svc);
        if (kr != kIOReturnSuccess || !plug) { printf("plugin create failed 0x%08x\n", kr); continue; }
        IOUSBDeviceInterface **dev = NULL;
        (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&dev);
        (*plug)->Release(plug);
        if (!dev) continue;

        UInt16 v, p, rel; UInt8 cls, sub, proto, ncfg, speed, cur = 0xff, im, ip, is;
        (*dev)->GetDeviceVendor(dev, &v); (*dev)->GetDeviceProduct(dev, &p);
        (*dev)->GetDeviceReleaseNumber(dev, &rel);
        (*dev)->GetDeviceClass(dev, &cls); (*dev)->GetDeviceSubClass(dev, &sub);
        (*dev)->GetDeviceProtocol(dev, &proto);
        (*dev)->GetNumberOfConfigurations(dev, &ncfg);
        (*dev)->GetDeviceSpeed(dev, &speed);
        (*dev)->USBGetManufacturerStringIndex(dev, &im);
        (*dev)->USBGetProductStringIndex(dev, &ip);
        (*dev)->USBGetSerialNumberStringIndex(dev, &is);
        kern_return_t ckr = (*dev)->GetConfiguration(dev, &cur);
        printf("DEVICE vid=0x%04x pid=0x%04x bcdDevice=0x%04x class=0x%02x sub=0x%02x proto=0x%02x numConfigs=%u speedEnum=%u\n",
               v, p, rel, cls, sub, proto, ncfg, speed);
        printf("  currentConfiguration=%u (kr=0x%08x)\n", cur, ckr);
        print_string(dev, im, "iManufacturer");
        print_string(dev, ip, "iProduct");
        print_string(dev, is, "iSerial");
        for (UInt8 i = 0; i < ncfg; i++) {
            IOUSBConfigurationDescriptorPtr cfg = NULL;
            kr = (*dev)->GetConfigurationDescriptorPtr(dev, i, &cfg);
            if (kr != kIOReturnSuccess || !cfg) { printf("config %u: error 0x%08x\n", i, kr); continue; }
            dump_config(dev, (const UInt8 *)cfg, USBToHostWord(cfg->wTotalLength));
        }
        (*dev)->Release(dev);
    }
    IOObjectRelease(it);
    if (!found) printf("No device with VID 0x%04x PID 0x%04x found\n", VID, PID);
    return found ? 0 : 2;
}
