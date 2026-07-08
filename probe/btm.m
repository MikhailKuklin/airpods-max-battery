// Probe the private BluetoothManager framework (what Control Center uses) for
// the exact connected-device battery. If this returns ~40% matching the iPhone,
// the real app should use it.
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>

static long callInt(id obj, const char *sel) {
    SEL s = sel_registerName(sel);
    if (![obj respondsToSelector:s]) return -999;
    long (*fn)(id, SEL) = (long (*)(id, SEL))objc_msgSend;
    return fn(obj, s);
}
static id callObj(id obj, const char *sel) {
    SEL s = sel_registerName(sel);
    if (![obj respondsToSelector:s]) return nil;
    id (*fn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    return fn(obj, s);
}

int main() {
    @autoreleasepool {
        void *h = dlopen("/System/Library/PrivateFrameworks/BluetoothManager.framework/BluetoothManager", RTLD_NOW);
        if (!h) { printf("dlopen failed: %s\n", dlerror()); return 1; }
        Class BM = objc_getClass("BluetoothManager");
        if (!BM) { printf("no BluetoothManager class\n"); return 2; }
        id mgr = callObj(BM, "sharedInstance");
        printf("sharedInstance: %s\n", mgr ? "ok" : "nil");
        // let it populate
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.5]];

        printf("powerState=%ld available=%ld\n",
               callInt(mgr, "powerState"), callInt(mgr, "available"));
        id devs = callObj(mgr, "connectedDevices");
        NSArray *arr = [devs isKindOfClass:[NSArray class]] ? devs : nil;
        if (!arr.count) {
            printf("connectedDevices empty — trying 'devices'\n");
            id all = callObj(mgr, "devices");
            arr = [all isKindOfClass:[NSArray class]] ? all : nil;
        }
        printf("devices to inspect: %lu\n", (unsigned long)arr.count);
        const char *sels[] = {"batteryPercentSingle","batteryPercentCombined",
                              "batteryPercentCase","batteryPercentLeft",
                              "batteryPercentRight","batteryPercent", NULL};
        for (id d in arr) {
            id name = callObj(d, "name");
            printf("device: %-28s connected=%ld\n",
                   name ? [[name description] UTF8String] : "?",
                   callInt(d, "isConnected"));
            for (int i = 0; sels[i]; i++) {
                long v = callInt(d, sels[i]);
                if (v != -999) printf("   %s = %ld (0x%lx)\n", sels[i], v & 0xff, v);
            }
        }
    }
    return 0;
}
