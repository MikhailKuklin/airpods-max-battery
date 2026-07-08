import Foundation
import CoreBluetooth

// Live beacon monitor: logs byte[7] on every CHANGE and a heartbeat every 15s,
// with wall-clock timestamps, so we can see what (if anything) makes the
// AirPods Max refresh their broadcast battery value.

let APPLE: UInt16 = 0x004C
let LOG = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("airpods-max-battery/monitor.log")

func stamp() -> String {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
    return f.string(from: Date())
}
func emit(_ s: String) {
    let line = "\(stamp()) \(s)\n"
    FileHandle.standardOutput.write(line.data(using: .utf8)!)
    if let h = try? FileHandle(forWritingTo: LOG) { h.seekToEndOfFile(); h.write(line.data(using:.utf8)!); try? h.close() }
    else { try? line.write(to: LOG, atomically: true, encoding: .utf8) }
}

final class Mon: NSObject, CBCentralManagerDelegate {
    var c: CBCentralManager!
    var last = -1
    var lastRSSI = 0
    override init() { super.init(); try? "".write(to: LOG, atomically: true, encoding: .utf8) }
    func start() { c = CBCentralManager(delegate: self, queue: nil) }
    func centralManagerDidUpdateState(_ m: CBCentralManager) {
        if m.state == .poweredOn {
            m.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            emit("[scanning]")
        } else { emit("[state=\(m.state.rawValue)]"); exit(2) }
    }
    func centralManager(_ m: CBCentralManager, didDiscover p: CBPeripheral, advertisementData a: [String:Any], rssi: NSNumber) {
        guard let d = a[CBAdvertisementDataManufacturerDataKey] as? Data, d.count > 7,
              (UInt16(d[0]) | (UInt16(d[1])<<8)) == APPLE, d[2]==0x07,
              d[5]==0x1f, d[6]==0x20 else { return }
        let pct = Int(d[7]); lastRSSI = rssi.intValue
        if pct != last {
            emit("CHANGE \(last < 0 ? "—" : "\(last)%") -> \(pct)%   rssi=\(rssi.intValue)  raw7=0x\(String(format:"%02x",d[7]))")
            last = pct
        }
    }
}
let mon = Mon(); mon.start()
Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
    emit("heartbeat: still \(mon.last)%  rssi=\(mon.lastRSSI)")
}
RunLoop.main.run()
