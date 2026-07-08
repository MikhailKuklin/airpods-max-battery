import Foundation
import AppKit
import CoreBluetooth

// ─────────────────────────────────────────────────────────────────────────
// AirPods Max battery monitor — menu-bar app
//
// Reads the battery % from the Apple "proximity pairing" BLE advertisement
// (company 0x004C, message type 0x07). For AirPods Max the model bytes are
// 0x201f and the battery is a plain 0–100 byte at manufacturer-data index 7
// (validated against Control Center at 43%). No private frameworks.
//
// Shows the % in the menu bar, logs every reading to a CSV, and estimates
// how long a full charge lasts from the logged discharge slope.
// ─────────────────────────────────────────────────────────────────────────

let APPLE_COMPANY: UInt16 = 0x004C
let MAX_MODEL_LO: UInt8 = 0x1f      // model 0x201f, little-endian in the packet
let MAX_MODEL_HI: UInt8 = 0x20
// Battery is the exact 1% value at manufacturer-data index 14. (Index 7 is a
// status/wear flag that merely *looked* like battery during calibration because
// it coincidentally equalled 43; it freezes and goes to 0x01 when unworn.)
let BATTERY_INDEX = 14
let LOG_URL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("airpods-max-battery/battery_log.csv")
let LOG_INTERVAL: TimeInterval = 120   // don't write more than one row / 2 min
let UNKNOWN: UInt8 = 0xff

struct Sample { let t: Date; let pct: Int }

// ── Rolling analysis over the CSV ──────────────────────────────────────────
final class Analyzer {
    // Linear fit of pct vs. hours over the current discharge segment.
    // Returns (%/hour drain, r²) or nil if not enough monotonic-down data.
    static func drain(_ s: [Sample]) -> (rate: Double, hoursToEmpty: Double,
                                         fullRuntime: Double)? {
        guard s.count >= 2 else { return nil }
        // Take the tail since the last charge (pct went up) — that's the
        // current discharge run.
        var run: [Sample] = []
        for sample in s.reversed() {
            if let last = run.last, sample.pct < last.pct - 3 { break } // a jump up going backwards = a charge event
            run.append(sample)
        }
        run.reverse()
        guard run.count >= 2, let first = run.first, let last = run.last,
              last.pct < first.pct else { return nil }
        // Least-squares slope of pct over hours.
        let t0 = first.t.timeIntervalSince1970
        let xs = run.map { ($0.t.timeIntervalSince1970 - t0) / 3600.0 }
        let ys = run.map { Double($0.pct) }
        let n = Double(xs.count)
        let sx = xs.reduce(0,+), sy = ys.reduce(0,+)
        let sxx = zip(xs,xs).map(*).reduce(0,+)
        let sxy = zip(xs,ys).map(*).reduce(0,+)
        let denom = n*sxx - sx*sx
        guard denom != 0 else { return nil }
        let slope = (n*sxy - sx*sy) / denom          // %/hour (negative)
        guard slope < 0 else { return nil }
        let rate = -slope                             // %/hour drain, positive
        guard rate > 0.01 else { return nil }
        let toEmpty = Double(last.pct) / rate
        let full = 100.0 / rate
        return (rate, toEmpty, full)
    }
}

// ── CoreBluetooth reader ────────────────────────────────────────────────────
final class BatteryReader: NSObject, CBCentralManagerDelegate {
    private var central: CBCentralManager!
    private(set) var lastPct: Int = -1
    private var lastLogged: Date = .distantPast
    var onUpdate: ((Int) -> Void)?

    func start() { central = CBCentralManager(delegate: self, queue: nil) }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            c.scanForPeripherals(withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        case .unauthorized:
            onUpdate?(-2)
        case .poweredOff:
            onUpdate?(-3)
        default:
            break
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData a: [String: Any], rssi: NSNumber) {
        guard let d = a[CBAdvertisementDataManufacturerDataKey] as? Data,
              d.count > BATTERY_INDEX,
              (UInt16(d[0]) | (UInt16(d[1]) << 8)) == APPLE_COMPANY,
              d[2] == 0x07,
              d[5] == MAX_MODEL_LO, d[6] == MAX_MODEL_HI else { return }
        let raw = d[BATTERY_INDEX]
        guard raw != UNKNOWN, raw <= 100 else { return }
        let pct = Int(raw)
        if pct != lastPct {
            lastPct = pct
            onUpdate?(pct)
        }
        maybeLog(pct)
    }

    private func maybeLog(_ pct: Int) {
        let now = Date()
        guard now.timeIntervalSince(lastLogged) >= LOG_INTERVAL else { return }
        lastLogged = now
        appendLog(pct: pct, at: now)
    }

    private func appendLog(pct: Int, at t: Date) {
        let iso = ISO8601DateFormatter().string(from: t)
        let line = "\(iso),\(Int(t.timeIntervalSince1970)),\(pct)\n"
        let fm = FileManager.default
        try? fm.createDirectory(at: LOG_URL.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        if !fm.fileExists(atPath: LOG_URL.path) {
            try? "iso_time,epoch,percent\n".write(to: LOG_URL, atomically: true,
                                                  encoding: .utf8)
        }
        if let h = try? FileHandle(forWritingTo: LOG_URL) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        }
    }

    func loadSamples() -> [Sample] {
        guard let text = try? String(contentsOf: LOG_URL, encoding: .utf8)
        else { return [] }
        return text.split(separator: "\n").dropFirst().compactMap { row in
            let f = row.split(separator: ",")
            guard f.count >= 3, let epoch = Double(f[1]), let p = Int(f[2])
            else { return nil }
            return Sample(t: Date(timeIntervalSince1970: epoch), pct: p)
        }
    }
}

// ── Menu-bar UI ──────────────────────────────────────────────────────────────
final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let reader = BatteryReader()
    let menu = NSMenu()

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem.button?.title = "AirPods …"
        menu.delegate = self               // rebuild every time it's opened
        statusItem.menu = menu
        reader.onUpdate = { [weak self] pct in
            DispatchQueue.main.async { self?.render(pct) }
        }
        reader.start()
    }

    // Refresh the runtime estimate each time the user opens the menu.
    func menuNeedsUpdate(_ m: NSMenu) { render(reader.lastPct) }

    private func fmtHours(_ h: Double) -> String {
        if h.isInfinite || h.isNaN { return "—" }
        let hh = Int(h); let mm = Int((h - Double(hh)) * 60)
        return hh > 0 ? "\(hh)h \(mm)m" : "\(mm)m"
    }

    private func render(_ pct: Int) {
        switch pct {
        case -2: statusItem.button?.title = "AirPods ⚠︎ no BT permission"
        case -3: statusItem.button?.title = "AirPods ⚠︎ BT off"
        default: statusItem.button?.title = "🎧 \(pct)%"
        }

        menu.removeAllItems()
        menu.addItem(header("AirPods Max — \(pct >= 0 ? "\(pct)%" : "—")"))
        menu.addItem(.separator())

        if let a = Analyzer.drain(reader.loadSamples()) {
            menu.addItem(info(String(format: "Draining %.1f%%/hour", a.rate)))
            menu.addItem(info("Time to empty: \(fmtHours(a.hoursToEmpty))"))
            menu.addItem(info("Est. full-charge runtime: \(fmtHours(a.fullRuntime))"))
        } else {
            menu.addItem(info("Runtime: gathering data…"))
            menu.addItem(info("(needs a bit of discharge history)"))
        }

        menu.addItem(.separator())
        let logItem = NSMenuItem(title: "Open battery log (CSV)",
                                 action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)
        let quit = NSMenuItem(title: "Quit", action: #selector(quit),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func header(_ s: String) -> NSMenuItem {
        let i = NSMenuItem(title: s, action: nil, keyEquivalent: ""); i.isEnabled = false; return i
    }
    private func info(_ s: String) -> NSMenuItem {
        let i = NSMenuItem(title: s, action: nil, keyEquivalent: ""); i.isEnabled = false; return i
    }
    @objc private func openLog() { NSWorkspace.shared.open(LOG_URL) }
    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
app.run()
