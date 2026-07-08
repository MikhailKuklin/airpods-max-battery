import Foundation
import CoreBluetooth
let APPLE: UInt16 = 0x004C
final class V: NSObject, CBCentralManagerDelegate {
    var c: CBCentralManager!; var hits = 0
    func start(){ c = CBCentralManager(delegate:self, queue:nil) }
    func centralManagerDidUpdateState(_ m: CBCentralManager){
        if m.state == .poweredOn { m.scanForPeripherals(withServices:nil, options:[CBCentralManagerScanOptionAllowDuplicatesKey:true]) }
        else { print("state=\(m.state.rawValue)"); exit(2) }
    }
    func centralManager(_ m: CBCentralManager, didDiscover p: CBPeripheral, advertisementData a: [String:Any], rssi r: NSNumber){
        guard let d = a[CBAdvertisementDataManufacturerDataKey] as? Data, d.count >= 8 else { return }
        guard (UInt16(d[0]) | (UInt16(d[1])<<8)) == APPLE, d[2]==0x07 else { return }
        guard d[5]==0x1f, d[6]==0x20 else { return } // model 0x201f = AirPods Max
        let batt = d[7]
        print("byte[7] = 0x\(String(format:"%02x",batt)) = \(batt)%   rssi=\(r.intValue)")
        hits += 1
        if hits >= 3 { exit(0) }
    }
}
let v = V(); v.start()
DispatchQueue.main.asyncAfter(deadline: .now()+15){ print("timeout, hits=\(v.hits)"); exit(v.hits>0 ? 0 : 1) }
RunLoop.main.run()
