import Foundation
import CoreBluetooth

// Throwaway probe: scan BLE, dump every Apple (company 0x004C) manufacturer
// advertisement with raw bytes + RSSI so we can see whether the AirPods Max
// broadcast a battery-bearing packet on this machine, and in what layout.

let APPLE: UInt16 = 0x004C

final class Probe: NSObject, CBCentralManagerDelegate {
    var central: CBCentralManager!
    var seen = Set<String>()

    func start() {
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            print("[state] poweredOn — scanning for Apple advertisements…")
            c.scanForPeripherals(withServices: nil,
                                 options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        case .unauthorized:
            print("[state] UNAUTHORIZED — this process lacks Bluetooth permission (TCC).")
            exit(2)
        case .poweredOff:
            print("[state] Bluetooth is OFF."); exit(3)
        case .unsupported:
            print("[state] unsupported"); exit(4)
        default:
            print("[state] \(c.state.rawValue)")
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              mfg.count >= 2 else { return }
        let company = UInt16(mfg[0]) | (UInt16(mfg[1]) << 8)
        guard company == APPLE else { return }
        let payload = mfg.subdata(in: 2..<mfg.count)
        guard let type = payload.first else { return }
        // 0x07 = proximity pairing (battery-bearing), 0x10 = nearby, 0x0C = handoff…
        let key = "\(p.identifier)-\(type)-\(mfg.count)"
        if seen.contains(key) { return }
        seen.insert(key)
        let hex = mfg.map { String(format: "%02x", $0) }.joined()
        let name = p.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "?"
        print(String(format: "type=0x%02x len=%2d rssi=%4d name=%@ id=%@",
                     type, mfg.count, RSSI.intValue, name, p.identifier.uuidString))
        print("   raw=\(hex)")
    }
}

let probe = Probe()
probe.start()
// Auto-exit so it never hangs the session.
DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
    print("[done] 20s elapsed, \(probe.seen.count) unique Apple packet(s) seen.")
    exit(0)
}
RunLoop.main.run()
