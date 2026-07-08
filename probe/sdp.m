// Discover the AirPods Max SDP services + their L2CAP PSMs, so we can open the
// correct Apple Accessory Protocol channel (the PSM is not always 0x1001).
#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        // Pass your AirPods' Bluetooth address, e.g.  ./sdp aa-bb-cc-dd-ee-ff
        NSString *addr = argc > 1 ? @(argv[1]) : @"aa-bb-cc-dd-ee-ff";
        IOBluetoothDevice *dev = [IOBluetoothDevice deviceWithAddressString:addr];
        if (!dev) { printf("no device\n"); return 1; }
        printf("name=%s connected=%d\n", [[dev name] UTF8String], [dev isConnected]);

        // Try cached services first; else run an SDP query.
        NSArray *svcs = [dev services];
        if (!svcs.count) {
            printf("no cached services — running SDP query…\n");
            IOReturn r = [dev performSDPQuery:nil];
            printf("performSDPQuery = 0x%x\n", r);
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:3.0]];
            svcs = [dev services];
        }
        printf("service records: %lu\n", (unsigned long)svcs.count);

        for (IOBluetoothSDPServiceRecord *rec in svcs) {
            NSString *name = [rec getServiceName];
            BluetoothL2CAPPSM psm = 0;
            BluetoothRFCOMMChannelID rfcomm = 0;
            IOReturn hasL2 = [rec getL2CAPPSM:&psm];
            IOReturn hasRF = [rec getRFCOMMChannelID:&rfcomm];
            printf("• %-34s", name ? [name UTF8String] : "(unnamed)");
            if (hasL2 == kIOReturnSuccess) printf("  L2CAP PSM=0x%04x", psm);
            if (hasRF == kIOReturnSuccess) printf("  RFCOMM ch=%d", rfcomm);
            printf("\n");
        }
    }
    return 0;
}
