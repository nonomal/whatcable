/*
 * 26_displayport_altmode.c - Probe DisplayPort alt-mode properties.
 * DP alt-mode negotiation data (lane count, link rate, pin assignment)
 * might be exposed on IODisplayConnect or related services.
 *
 * Compile: clang -framework IOKit -framework CoreFoundation -o 26_displayport_altmode 26_displayport_altmode.c
 */

#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void printCFType(CFTypeRef value, int indent) {
    char pad[64] = {0};
    for (int i = 0; i < indent && i < 60; i++) pad[i] = ' ';

    if (!value) { printf("%s(null)\n", pad); return; }

    CFTypeID tid = CFGetTypeID(value);
    if (tid == CFStringGetTypeID()) {
        char buf[512];
        CFStringGetCString(value, buf, sizeof(buf), kCFStringEncodingUTF8);
        printf("%s\"%s\"\n", pad, buf);
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
    } else if (tid == CFDictionaryGetTypeID()) {
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
        for (CFIndex i = 0; i < count; i++) {
            printf("%s  [%ld] ", pad, (long)i);
            printCFType(CFArrayGetValueAtIndex(value, i), indent + 4);
        }
    } else {
        printf("%s<type %lu>\n", pad, (unsigned long)tid);
    }
}

static void dumpAllProperties(io_service_t service, const char *label) {
    CFMutableDictionaryRef props = NULL;
    kern_return_t kr = IORegistryEntryCreateCFProperties(service, &props,
        kCFAllocatorDefault, 0);
    if (kr != KERN_SUCCESS || !props) return;

    printf("\n--- %s ---\n", label);

    CFIndex n = CFDictionaryGetCount(props);
    const void **keys = malloc(n * sizeof(void*));
    const void **vals = malloc(n * sizeof(void*));
    CFDictionaryGetKeysAndValues(props, keys, vals);
    for (CFIndex i = 0; i < n; i++) {
        char kbuf[256];
        CFStringGetCString(keys[i], kbuf, sizeof(kbuf), kCFStringEncodingUTF8);
        printf("  %s = ", kbuf);
        printCFType(vals[i], 4);
    }
    free(keys); free(vals);
    CFRelease(props);
}

int main(void) {
    printf("Running as uid=%d\n\n", getuid());

    io_iterator_t iter;
    kern_return_t kr;
    io_service_t svc;

    // Search for display-related services
    const char *classes[] = {
        "IODisplayConnect",
        "IOFramebuffer",
        "IOBacklightDisplay",
        "AppleCLCD2",
        "IOPortTransportComponentCCDisplayPort",
        "IOPortFeatureDisplayPort",
        "IOPortTransportStateCCDisplayPort",
        "DCPAVDevice",
        "IOMobileFramebufferShim",
        NULL
    };

    for (int c = 0; classes[c]; c++) {
        printf("=== %s ===\n", classes[c]);
        kr = IOServiceGetMatchingServices(kIOMainPortDefault,
            IOServiceMatching(classes[c]), &iter);
        if (kr != KERN_SUCCESS) {
            printf("  (no matching services)\n\n");
            continue;
        }

        int count = 0;
        while ((svc = IOIteratorNext(iter)) != 0) {
            char label[256];
            io_name_t name;
            IORegistryEntryGetName(svc, name);
            snprintf(label, sizeof(label), "%s[%d] \"%s\"", classes[c], count, name);
            dumpAllProperties(svc, label);
            IOObjectRelease(svc);
            count++;
        }
        IOObjectRelease(iter);
        if (count == 0) printf("  (no instances)\n");
        printf("\n");
    }

    // Also search for anything with "DisplayPort" or "DP" in name
    printf("=== Registry search: *DisplayPort* services ===\n");
    kr = IOServiceGetMatchingServices(kIOMainPortDefault,
        IOServiceMatching("IOService"), &iter);
    if (kr == KERN_SUCCESS) {
        int found = 0;
        while ((svc = IOIteratorNext(iter)) != 0) {
            io_name_t name;
            IORegistryEntryGetName(svc, name);
            if (strcasestr(name, "DisplayPort") || strcasestr(name, "AltMode") ||
                strcasestr(name, "DPAlt")) {
                char label[256];
                snprintf(label, sizeof(label), "DP-match: \"%s\"", name);
                dumpAllProperties(svc, label);
                found++;
            }
            IOObjectRelease(svc);
        }
        IOObjectRelease(iter);
        printf("  Found %d DP-related services\n", found);
    }

    // Check IOPortTransportComponentCC children for DP-related entries
    printf("\n=== IOPortTransportComponentCC children (looking for DP) ===\n");
    kr = IOServiceGetMatchingServices(kIOMainPortDefault,
        IOServiceMatching("IOPortTransportComponentCC"), &iter);
    if (kr == KERN_SUCCESS) {
        while ((svc = IOIteratorNext(iter)) != 0) {
            io_name_t name;
            IORegistryEntryGetName(svc, name);

            io_iterator_t childIter;
            kr = IORegistryEntryGetChildIterator(svc, kIOServicePlane, &childIter);
            if (kr == KERN_SUCCESS) {
                io_service_t child;
                while ((child = IOIteratorNext(childIter)) != 0) {
                    io_name_t childName;
                    IORegistryEntryGetName(child, childName);
                    if (strcasestr(childName, "DP") || strcasestr(childName, "Display") ||
                        strcasestr(childName, "Video") || strcasestr(childName, "Alt")) {
                        char label[256];
                        snprintf(label, sizeof(label), "%s -> %s", name, childName);
                        dumpAllProperties(child, label);
                    }
                    IOObjectRelease(child);
                }
                IOObjectRelease(childIter);
            }
            IOObjectRelease(svc);
        }
        IOObjectRelease(iter);
    }

    return 0;
}
