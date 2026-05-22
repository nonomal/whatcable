// Watch for transient IORegistry properties during cable plug events.
// Some properties might appear briefly during PD negotiation then
// disappear. We need to catch them at the right moment.
//
// Strategy: register notifications, and on each one, do a FULL
// property dump of the service AND all its children, looking for
// any property we haven't seen before.
//
// Also specifically watches "SOP UVDM Update Count" changes and
// decodes the "CF VID Status Reg" data.
//
// Compile: clang -framework IOKit -framework CoreFoundation -o transient_props 16_transient_props.c
// Run: sudo ./transient_props
// TIP: Unplug cable, wait 3 seconds, plug cable back in.

#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <time.h>

// Track which properties we've already seen so we can spot new ones
#define MAX_SEEN 2048
static char seenProps[MAX_SEEN][256];
static int seenCount = 0;

static int alreadySeen(const char *className, const char *propName) {
    char key[512];
    snprintf(key, sizeof(key), "%s::%s", className, propName);
    for (int i = 0; i < seenCount; i++) {
        if (strcmp(seenProps[i], key) == 0) return 1;
    }
    if (seenCount < MAX_SEEN) {
        strncpy(seenProps[seenCount++], key, 255);
    }
    return 0;
}

static void dumpAllProperties(io_service_t service, const char *prefix, int showAll) {
    io_name_t className;
    IOObjectGetClass(service, className);

    CFMutableDictionaryRef props = NULL;
    kern_return_t kr = IORegistryEntryCreateCFProperties(
        service, &props, kCFAllocatorDefault, 0);
    if (kr != KERN_SUCCESS || !props) return;

    CFIndex count = CFDictionaryGetCount(props);
    const void **keys = malloc(sizeof(void*) * count);
    const void **vals = malloc(sizeof(void*) * count);
    CFDictionaryGetKeysAndValues(props, keys, vals);

    for (CFIndex i = 0; i < count; i++) {
        char keyBuf[256];
        CFStringGetCString(keys[i], keyBuf, sizeof(keyBuf), kCFStringEncodingUTF8);

        int isNew = !alreadySeen(className, keyBuf);
        if (!showAll && !isNew) continue;

        CFTypeID tid = CFGetTypeID(vals[i]);

        if (isNew) printf("  %s*** NEW *** ", prefix);
        else printf("  %s", prefix);

        if (tid == CFDataGetTypeID()) {
            CFDataRef data = (CFDataRef)vals[i];
            CFIndex len = CFDataGetLength(data);
            const uint8_t *bytes = CFDataGetBytePtr(data);
            printf("%s.%s = <data %ld bytes> [", className, keyBuf, len);
            for (CFIndex j = 0; j < len && j < 64; j++)
                printf(" %02x", bytes[j]);
            if (len > 64) printf(" ...");
            printf(" ]\n");
        } else if (tid == CFNumberGetTypeID()) {
            int64_t val = 0;
            CFNumberGetValue(vals[i], kCFNumberSInt64Type, &val);
            printf("%s.%s = %lld (0x%llx)\n", className, keyBuf, val, val);
        } else if (tid == CFStringGetTypeID()) {
            char valBuf[512];
            CFStringGetCString(vals[i], valBuf, sizeof(valBuf), kCFStringEncodingUTF8);
            printf("%s.%s = \"%s\"\n", className, keyBuf, valBuf);
        } else if (tid == CFBooleanGetTypeID()) {
            printf("%s.%s = %s\n", className, keyBuf,
                CFBooleanGetValue(vals[i]) ? "true" : "false");
        } else if (tid == CFDictionaryGetTypeID()) {
            printf("%s.%s = <dict>\n", className, keyBuf);
        } else if (tid == CFArrayGetTypeID()) {
            printf("%s.%s = <array len=%ld>\n", className, keyBuf,
                CFArrayGetCount(vals[i]));
        } else {
            printf("%s.%s = <type %lu>\n", className, keyBuf, tid);
        }
    }

    free(keys);
    free(vals);
    CFRelease(props);
}

static void walkChildren(io_service_t parent, const char *prefix, int showAll) {
    io_iterator_t childIter;
    kern_return_t kr = IORegistryEntryGetChildIterator(parent, kIOServicePlane, &childIter);
    if (kr != KERN_SUCCESS) return;

    io_service_t child;
    while ((child = IOIteratorNext(childIter))) {
        io_name_t className;
        IOObjectGetClass(child, className);

        char newPrefix[128];
        snprintf(newPrefix, sizeof(newPrefix), "%s  ", prefix);

        dumpAllProperties(child, newPrefix, showAll);
        walkChildren(child, newPrefix, showAll);
        IOObjectRelease(child);
    }
    IOObjectRelease(childIter);
}

// Track UVDM count per port
static int lastUVDMCount[8] = {0};

static void interestCallback(void *refcon, io_service_t service,
                              uint32_t messageType, void *messageArgument) {
    io_name_t className;
    IOObjectGetClass(service, className);

    // Get timestamp
    time_t now = time(NULL);
    struct tm *tm = localtime(&now);
    char timeBuf[32];
    strftime(timeBuf, sizeof(timeBuf), "%H:%M:%S", tm);

    printf("\n[%s] NOTIFY %s type=0x%08x arg=%p\n",
        timeBuf, className, messageType, messageArgument);

    // Check UVDM count specifically
    CFNumberRef uvdmCount = (CFNumberRef)IORegistryEntryCreateCFProperty(
        service, CFSTR("SOP UVDM Update Count"), kCFAllocatorDefault, 0);
    if (uvdmCount) {
        int count = 0;
        CFNumberGetValue(uvdmCount, kCFNumberIntType, &count);
        CFRelease(uvdmCount);

        CFNumberRef portNum = (CFNumberRef)IORegistryEntryCreateCFProperty(
            service, CFSTR("PortNumber"), kCFAllocatorDefault, 0);
        int port = 0;
        if (portNum) {
            CFNumberGetValue(portNum, kCFNumberIntType, &port);
            CFRelease(portNum);
        }

        if (count != lastUVDMCount[port % 8]) {
            printf("  !!! SOP UVDM Update Count CHANGED: %d -> %d (port %d) !!!\n",
                lastUVDMCount[port % 8], count, port);
            lastUVDMCount[port % 8] = count;

            // Full dump when UVDM count changes
            printf("  Full property dump after UVDM change:\n");
            dumpAllProperties(service, "    ", 1);

            // Also walk children for new properties
            printf("  Children after UVDM change:\n");
            walkChildren(service, "    ", 1);
        }
    }

    // Always check for new properties we haven't seen
    dumpAllProperties(service, "  ", 0);

    // Walk children looking for new services/properties
    walkChildren(service, "  ", 0);
}

int main(void) {
    printf("Running as uid=%d\n\n", getuid());

    IONotificationPortRef notifyPort = IONotificationPortCreate(kIOMainPortDefault);
    CFRunLoopSourceRef rlSrc = IONotificationPortGetRunLoopSource(notifyPort);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), rlSrc, kCFRunLoopDefaultMode);

    // First pass: catalog all existing properties
    printf("=== Cataloging existing properties ===\n\n");
    const char *classes[] = {
        "AppleHPMARMSPMI",
        "AppleHPMDeviceHALType3",
        "AppleHPMInterfaceType10",
        "AppleHPMInterfaceType11",
        "IOPortTransportStateCC",
        "IOPortTransportComponentCCUSBPDSOP",
        "IOPortTransportComponentCCUSBPDSOPp",
        "IOPortTransportComponentCCUSBPDSOPpp",
        "IOAccessoryManager",
        NULL
    };

    for (int i = 0; classes[i]; i++) {
        io_iterator_t iter;
        kern_return_t kr = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching(classes[i]),
            &iter);
        if (kr != KERN_SUCCESS) continue;

        io_service_t svc;
        int idx = 0;
        while ((svc = IOIteratorNext(iter))) {
            printf("  %s[%d]:\n", classes[i], idx);
            dumpAllProperties(svc, "    ", 1);

            // Record UVDM count
            CFNumberRef uvdmCount = (CFNumberRef)IORegistryEntryCreateCFProperty(
                svc, CFSTR("SOP UVDM Update Count"), kCFAllocatorDefault, 0);
            if (uvdmCount) {
                int count = 0;
                CFNumberGetValue(uvdmCount, kCFNumberIntType, &count);
                CFRelease(uvdmCount);

                CFNumberRef portNum = (CFNumberRef)IORegistryEntryCreateCFProperty(
                    svc, CFSTR("PortNumber"), kCFAllocatorDefault, 0);
                int port = 0;
                if (portNum) {
                    CFNumberGetValue(portNum, kCFNumberIntType, &port);
                    CFRelease(portNum);
                }
                lastUVDMCount[port % 8] = count;
                printf("    Initial UVDM count for port %d: %d\n", port, count);
            }

            IOObjectRelease(svc);
            idx++;
        }
        IOObjectRelease(iter);
    }

    IONotificationPortDestroy(notifyPort);

    printf("\n\nTotal unique properties cataloged: %d\n", seenCount);
    return 0;
}
