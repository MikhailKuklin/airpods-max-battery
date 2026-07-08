// AAP battery reader v2: establish baseband, open the AAP L2CAP channel,
// send the handshake + notification-enable, and parse battery notifications.
#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>

static const uint8_t HANDSHAKE[] = {0x00,0x00,0x04,0x00,0x01,0x00,0x02,0x00,
                                    0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00};
static const uint8_t SETFEAT[]   = {0x04,0x00,0x04,0x00,0x0f,0x00,0xff,0xff,0xfe,0xff};
static const uint8_t REQNOTE[]   = {0x04,0x00,0x04,0x00,0x0f,0x00,0xff,0xff,0xff,0xff};

@interface Reader : NSObject <IOBluetoothL2CAPChannelDelegate>
@property (strong) IOBluetoothL2CAPChannel *ch;
@end

@implementation Reader
- (void)send:(const uint8_t*)b len:(int)n tag:(const char*)tag {
    IOReturn r = [self.ch writeSync:(void*)b length:n];
    printf("  TX %-12s -> 0x%x\n", tag, r);
}
- (void)l2capChannelOpenComplete:(IOBluetoothL2CAPChannel*)c status:(IOReturn)err {
    printf("openComplete status=0x%x\n", err);
    if (err != kIOReturnSuccess) return;
    [self send:HANDSHAKE len:sizeof(HANDSHAKE) tag:"handshake"];
    [self send:SETFEAT   len:sizeof(SETFEAT)   tag:"setfeatures"];
    [self send:REQNOTE   len:sizeof(REQNOTE)   tag:"reqnotify"];
}
- (void)l2capChannelData:(IOBluetoothL2CAPChannel*)c data:(void*)d length:(size_t)n {
    NSMutableString *hex = [NSMutableString string];
    uint8_t *b = (uint8_t*)d;
    for (size_t i=0;i<n;i++) [hex appendFormat:@"%02x", b[i]];
    printf("RX(%zu): %s\n", n, [hex UTF8String]);
    // battery notification: 04 00 04 00 04 00 <count> then 5-byte entries
    if (n >= 8 && b[0]==0x04 && b[4]==0x04) {
        int count = b[6], i = 7;
        for (int k=0;k<count && i+2 < (int)n;k++,i+=5) {
            printf("   → component type=0x%02x level=%d%% status=0x%02x\n",
                   b[i], b[i+1], b[i+2]);
        }
    }
}
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        // Pass your AirPods' Bluetooth address, e.g.  ./aap2 aa-bb-cc-dd-ee-ff
        NSString *addr = argc > 1 ? @(argv[1]) : @"aa-bb-cc-dd-ee-ff";
        IOBluetoothDevice *dev = [IOBluetoothDevice deviceWithAddressString:addr];
        printf("connected=%d\n", [dev isConnected]);
        IOReturn oc = [dev openConnection];
        printf("openConnection = 0x%x\n", oc);

        Reader *rd = [Reader new];
        IOBluetoothL2CAPChannel *ch = nil;
        IOReturn r = [dev openL2CAPChannelSync:&ch withPSM:0x1001 delegate:rd];
        printf("openL2CAPChannelSync = 0x%x  channel=%p\n", r, ch);
        rd.ch = ch;
        if (r != kIOReturnSuccess) {
            // try async as fallback
            printf("sync failed, trying async…\n");
            IOReturn ra = [dev openL2CAPChannelAsync:&ch withPSM:0x1001 delegate:rd];
            printf("openL2CAPChannelAsync = 0x%x\n", ra);
            rd.ch = ch;
        }
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:12.0]];
        printf("[done]\n");
    }
    return 0;
}
