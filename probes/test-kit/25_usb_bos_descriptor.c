/*
 * 25_usb_bos_descriptor.c - Read BOS (Binary Object Store) descriptors from
 * IOUSBHostDevice services. Cables with USB4 routers or Billboard devices
 * expose capability descriptors in userland without entitlements.
 *
 * Compile: clang -framework IOKit -framework CoreFoundation -o 25_usb_bos_descriptor 25_usb_bos_descriptor.c
 */

#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach/mach.h>

static void printCFType(CFTypeRef value, int indent) {
    char pad[64] = {0};
    for (int i = 0; i < indent && i < 60; i++) pad[i] = ' ';

    if (!value) { printf("%s(null)\n", pad); return; }

    CFTypeID tid = CFGetTypeID(value);
    if (tid == CFStringGetTypeID()) {
        char buf[512];
        CFStringGetCString(value, buf, sizeof(buf), kCFStringEncodingUTF8);
        printf("%s%s\n", pad, buf);
    } else if (tid == CFNumberGetTypeID()) {
        long long num = 0;
        CFNumberGetValue(value, kCFNumberLongLongType, &num);
        printf("%s%lld (0x%llx)\n", pad, num, num);
    } else if (tid == CFDataGetTypeID()) {
        CFIndex len = CFDataGetLength(value);
        const UInt8 *bytes = CFDataGetBytePtr(value);
        printf("%sData[%ld]: ", pad, (long)len);
        for (CFIndex i = 0; i < len && i < 64; i++)
            printf("%02x ", bytes[i]);
        if (len > 64) printf("...");
        printf("\n");
    } else if (tid == CFBooleanGetTypeID()) {
        printf("%s%s\n", pad, CFBooleanGetValue(value) ? "true" : "false");
    } else if (tid == CFDictionaryGetTypeID()) {
        CFIndex count = CFDictionaryGetCount(value);
        printf("%sDict[%ld]:\n", pad, (long)count);
        CFIndex n = CFDictionaryGetCount(value);
        const void **keys = malloc(n * sizeof(void*));
        const void **vals = malloc(n * sizeof(void*));
        CFDictionaryGetKeysAndValues(value, keys, vals);
        for (CFIndex i = 0; i < n; i++) {
            char kbuf[256];
            CFStringGetCString(keys[i], kbuf, sizeof(kbuf), kCFStringEncodingUTF8);
            printf("%s  %s = ", pad, kbuf);
            printCFType(vals[i], indent + 4);
        }
        free(keys); free(vals);
    } else if (tid == CFArrayGetTypeID()) {
        CFIndex count = CFArrayGetCount(value);
        printf("%sArray[%ld]:\n", pad, (long)count);
        for (CFIndex i = 0; i < count; i++) {
            printf("%s  [%ld] ", pad, (long)i);
            printCFType(CFArrayGetValueAtIndex(value, i), indent + 4);
        }
    } else {
        printf("%s<unknown CF type %lu>\n", pad, (unsigned long)tid);
    }
}

static void dumpServiceProperties(io_service_t service, const char *label) {
    CFMutableDictionaryRef props = NULL;
    kern_return_t kr = IORegistryEntryCreateCFProperties(service, &props,
        kCFAllocatorDefault, 0);
    if (kr != KERN_SUCCESS || !props) return;

    printf("\n--- %s ---\n", label);

    // Key properties for BOS/Billboard
    const char *interesting[] = {
        "USB Product Name", "USB Vendor Name", "idVendor", "idProduct",
        "bcdUSB", "bDeviceClass", "bDeviceSubClass", "bDeviceProtocol",
        "USB Speed", "UsbDeviceSpeed", "PortNum",
        "BOSDescriptor", "BOS Descriptor", "bos-descriptor",
        "BillboardCapability", "Billboard", "billboard",
        "USB4Version", "USB4", "usb4-capabilities",
        "SuperSpeed", "SuperSpeedPlus", "SSPCapability",
        "bNumConfigurations", "locationID", "sessionID",
        "kUSBContainerID", "ContainerID",
        "USB Serial Number", "iSerialNumber",
        NULL
    };

    for (int i = 0; interesting[i]; i++) {
        CFStringRef key = CFStringCreateWithCString(NULL, interesting[i], kCFStringEncodingUTF8);
        CFTypeRef val = CFDictionaryGetValue(props, key);
        if (val) {
            printf("  %s = ", interesting[i]);
            printCFType(val, 4);
        }
        CFRelease(key);
    }

    // Also check for any key containing "BOS", "Billboard", "Capability", "USB4"
    CFIndex n = CFDictionaryGetCount(props);
    const void **keys = malloc(n * sizeof(void*));
    const void **vals = malloc(n * sizeof(void*));
    CFDictionaryGetKeysAndValues(props, keys, vals);
    for (CFIndex i = 0; i < n; i++) {
        char kbuf[256];
        CFStringGetCString(keys[i], kbuf, sizeof(kbuf), kCFStringEncodingUTF8);
        if (strcasestr(kbuf, "BOS") || strcasestr(kbuf, "Billboard") ||
            strcasestr(kbuf, "USB4") || strcasestr(kbuf, "Capability") ||
            strcasestr(kbuf, "Descriptor") || strcasestr(kbuf, "Speed") ||
            strcasestr(kbuf, "Generation") || strcasestr(kbuf, "Lane") ||
            strcasestr(kbuf, "Tunnel")) {
            printf("  [MATCH] %s = ", kbuf);
            printCFType(vals[i], 4);
        }
    }
    free(keys); free(vals);

    // Try to open user client and get device descriptor
    io_connect_t conn;
    kr = IOServiceOpen(service, mach_task_self(), 0, &conn);
    if (kr == KERN_SUCCESS) {
        printf("  [OPEN] User client opened successfully (type=0)\n");

        // Try GetDeviceDescriptor (selector varies)
        uint64_t output[32];
        uint32_t outputCnt = 32;
        for (uint32_t sel = 0; sel < 10; sel++) {
            kr = IOConnectCallScalarMethod(conn, sel, NULL, 0, output, &outputCnt);
            if (kr == KERN_SUCCESS) {
                printf("  [METHOD] selector %u returned success, output[0]=0x%llx\n", sel, output[0]);
            }
            outputCnt = 32;
        }
        IOServiceClose(conn);
    } else {
        printf("  [OPEN] Failed: 0x%x\n", kr);
    }

    CFRelease(props);
}

int main(void) {
    printf("Running as uid=%d\n\n", getuid());

    // Find all IOUSBHostDevice services
    printf("=== IOUSBHostDevice services ===\n");
    io_iterator_t iter;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault,
        IOServiceMatching("IOUSBHostDevice"), &iter);

    if (kr == KERN_SUCCESS) {
        io_service_t svc;
        int count = 0;
        while ((svc = IOIteratorNext(iter)) != 0) {
            io_name_t name;
            IORegistryEntryGetName(svc, name);
            char label[256];
            snprintf(label, sizeof(label), "IOUSBHostDevice[%d] \"%s\"", count, name);
            dumpServiceProperties(svc, label);
            IOObjectRelease(svc);
            count++;
        }
        IOObjectRelease(iter);
        printf("\nTotal IOUSBHostDevice services: %d\n", count);
    }

    // Also look for AppleUSB4Hub / USB4 router services
    printf("\n=== USB4 Router/Hub services ===\n");
    const char *usb4Classes[] = {
        "AppleUSB4Hub", "IOThunderboltUSB4Router",
        "AppleUSB40DevicePort", "AppleUSB40HostPort",
        "IOUSBHostHubDevice", NULL
    };
    for (int c = 0; usb4Classes[c]; c++) {
        kr = IOServiceGetMatchingServices(kIOMainPortDefault,
            IOServiceMatching(usb4Classes[c]), &iter);
        if (kr == KERN_SUCCESS) {
            io_service_t svc;
            int count = 0;
            while ((svc = IOIteratorNext(iter)) != 0) {
                char label[256];
                snprintf(label, sizeof(label), "%s[%d]", usb4Classes[c], count);
                dumpServiceProperties(svc, label);
                IOObjectRelease(svc);
                count++;
            }
            IOObjectRelease(iter);
            if (count > 0) printf("  Found %d %s\n", count, usb4Classes[c]);
        }
    }

    // Look for Billboard class
    printf("\n=== Billboard devices ===\n");
    kr = IOServiceGetMatchingServices(kIOMainPortDefault,
        IOServiceMatching("IOUSBHostBillboardDevice"), &iter);
    if (kr == KERN_SUCCESS) {
        io_service_t svc;
        int count = 0;
        while ((svc = IOIteratorNext(iter)) != 0) {
            char label[256];
            snprintf(label, sizeof(label), "Billboard[%d]", count);
            dumpServiceProperties(svc, label);
            IOObjectRelease(svc);
            count++;
        }
        IOObjectRelease(iter);
        printf("  Found %d billboard devices\n", count);
    } else {
        printf("  No IOUSBHostBillboardDevice class found\n");
    }

    return 0;
}
