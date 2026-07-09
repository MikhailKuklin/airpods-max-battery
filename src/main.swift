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
// While worn/awake the Max broadcast the advertisement many times a second; in
// the case or off the head they go silent. If we haven't heard a reading in this
// long, the displayed % is stale (last-known), not live.
let STALE_SECONDS: TimeInterval = 300

struct Sample { let t: Date; let pct: Int }

// ── Rolling analysis over the CSV ──────────────────────────────────────────
final class Analyzer {
    // Active drain rate EXCLUDING idle time. We log ~every 2 min while the Max
    // are in use and broadcasting; a gap larger than GAP_MINUTES means they were
    // put away/asleep, so that interval contributes neither elapsed time nor
    // battery drop. Rate is therefore %-per-hour-of-actual-use, and runtimes are
    // hours of listening, not calendar hours.
    static let GAP_MINUTES = 15.0
    static let CHARGE_JUMP = 2   // a rise of more than this % = a charge event

    // One contiguous discharge run (between two charges), with idle gaps removed.
    struct Cycle {
        let start: Date, end: Date
        let activeHours: Double
        let drop: Double
        var rate: Double { activeHours > 0 ? drop / activeHours : 0 }   // %/hour
    }

    struct Summary {
        let current: Cycle?          // the in-progress (latest) discharge run
        let avgRate: Double?         // pooled %/hour across ALL logged cycles
        let cycleCount: Int          // number of measurable discharge cycles
        let trackingSince: Date?
        let sampleCount: Int
        let lastPct: Int?

        // Live time-to-empty from the current cycle's rate (falls back to the
        // lifetime average when the current cycle is too young to measure).
        func hoursToEmpty() -> Double? {
            guard let pct = lastPct, pct >= 0 else { return nil }
            let rate = current?.rate ?? avgRate
            guard let r = rate, r > 0.01 else { return nil }
            return Double(pct) / r
        }
        // What a full charge lasts, averaged over all history.
        func avgFullRuntime() -> Double? {
            guard let r = avgRate, r > 0.01 else { return nil }
            return 100.0 / r
        }
    }

    // Split the full log into discharge cycles (break at each charge event),
    // measure active drain within each, then pool them for a lifetime average.
    static func summarize(_ s: [Sample]) -> Summary {
        let sorted = s.sorted { $0.t < $1.t }
        guard !sorted.isEmpty else {
            return Summary(current: nil, avgRate: nil, cycleCount: 0,
                           trackingSince: nil, sampleCount: 0, lastPct: nil)
        }

        // Contiguous index ranges between charge events; the last one is live.
        var ranges: [(Int, Int)] = []
        var segStart = 0
        for i in 1..<sorted.count {
            if sorted[i].pct > sorted[i - 1].pct + CHARGE_JUMP {
                ranges.append((segStart, i - 1))
                segStart = i
            }
        }
        ranges.append((segStart, sorted.count - 1))

        func measure(_ from: Int, _ to: Int) -> Cycle? {
            guard to > from else { return nil }
            var activeHours = 0.0, drop = 0.0
            for i in (from + 1)...to {
                let older = sorted[i - 1], newer = sorted[i]
                let dt = newer.t.timeIntervalSince(older.t) / 3600.0
                if dt <= 0 || dt > GAP_MINUTES / 60.0 { continue }  // idle → skip
                activeHours += dt
                drop += Double(older.pct - newer.pct)               // ≥0 draining
            }
            guard activeHours > 0, drop > 0 else { return nil }
            return Cycle(start: sorted[from].t, end: sorted[to].t,
                         activeHours: activeHours, drop: drop)
        }

        var cycles: [Cycle] = []
        for r in ranges { if let c = measure(r.0, r.1) { cycles.append(c) } }
        let current = measure(ranges.last!.0, ranges.last!.1)

        let totalActive = cycles.reduce(0) { $0 + $1.activeHours }
        let totalDrop = cycles.reduce(0) { $0 + $1.drop }
        let avgRate = totalActive > 0 && totalDrop > 0
            ? totalDrop / totalActive : nil

        return Summary(current: current, avgRate: avgRate,
                       cycleCount: cycles.count, trackingSince: sorted.first?.t,
                       sampleCount: sorted.count, lastPct: sorted.last?.pct)
    }
}

// ── CoreBluetooth reader ────────────────────────────────────────────────────
final class BatteryReader: NSObject, CBCentralManagerDelegate {
    private var central: CBCentralManager!
    private(set) var lastPct: Int = -1            // last VALID battery %, or -1
    // The single source of truth for what the menu bar should show. Battery %
    // (0–100), or a negative status code: -1 searching, -2 no permission, -3 BT
    // off. Everything goes through set(display:) so a transient error state is
    // corrected by the very next valid reading — even if the % hasn't changed.
    private(set) var displayCode: Int = -1
    private(set) var lastSeen: Date = .distantPast   // last valid advertisement
    private var lastLogged: Date = .distantPast
    var onUpdate: ((Int) -> Void)?

    // The last reading is stale (Max asleep / in the case) if we've shown a real
    // % but haven't heard an advertisement in a while.
    var isStale: Bool {
        displayCode >= 0 && Date().timeIntervalSince(lastSeen) > STALE_SECONDS
    }
    var secondsSinceSeen: TimeInterval { Date().timeIntervalSince(lastSeen) }

    func start() { central = CBCentralManager(delegate: self, queue: nil) }

    private func set(display code: Int) {
        guard code != displayCode else { return }   // no spurious refreshes
        displayCode = code
        onUpdate?(code)
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            set(display: lastPct >= 0 ? lastPct : -1)   // resume; -1 = searching
            c.scanForPeripherals(withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        case .unauthorized:
            set(display: -2)
        case .poweredOff:
            set(display: -3)
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
        lastPct = pct
        lastSeen = Date()
        set(display: pct)          // also clears any stale error/searching title
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

    // Reset: archive the current log to a timestamped backup and start fresh.
    // The old data is moved aside (never deleted), so a reset is recoverable.
    @discardableResult
    func archiveLog() -> URL? {
        lastLogged = .distantPast          // log the next reading immediately
        let fm = FileManager.default
        guard fm.fileExists(atPath: LOG_URL.path) else { return nil }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let dst = LOG_URL.deletingLastPathComponent()
            .appendingPathComponent("battery_log.\(stamp.string(from: Date())).csv")
        try? fm.moveItem(at: LOG_URL, to: dst)
        return dst
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

    private var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem.button?.title = "AirPods …"
        menu.delegate = self               // rebuild every time it's opened
        statusItem.menu = menu
        reader.onUpdate = { [weak self] pct in
            DispatchQueue.main.async { self?.render(pct) }
        }
        reader.start()
        // The Max stop broadcasting when idle/in the case, so no callback tells
        // us the reading went stale — poll the title on a timer to catch it.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) {
            [weak self] _ in self?.updateTitle()
        }
    }

    // Refresh the runtime estimate each time the user opens the menu.
    func menuNeedsUpdate(_ m: NSMenu) { render(reader.displayCode) }

    private func fmtHours(_ h: Double) -> String {
        if h.isInfinite || h.isNaN { return "—" }
        let hh = Int(h); let mm = Int((h - Double(hh)) * 60)
        return hh > 0 ? "\(hh)h \(mm)m" : "\(mm)m"
    }

    private func fmtAgo(_ secs: TimeInterval) -> String {
        let s = Int(secs)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    private func titleString(_ pct: Int) -> String {
        switch pct {
        case -1: return "🎧 …"                       // searching for the Max
        case -2: return "AirPods ⚠︎ no BT permission"
        case -3: return "AirPods ⚠︎ BT off"
        // A leading ~ marks a last-known (stale) reading — the Max are silent.
        default: return reader.isStale ? "🎧 ~\(pct)%" : "🎧 \(pct)%"
        }
    }

    // Lightweight: just the menu-bar title (called every 30s by the timer).
    private func updateTitle() { statusItem.button?.title = titleString(reader.displayCode) }

    private func render(_ pct: Int) {
        updateTitle()

        menu.removeAllItems()
        menu.addItem(header("AirPods Max — \(pct >= 0 ? "\(pct)%" : "—")"))
        if reader.isStale {
            menu.addItem(info("Last seen \(fmtAgo(reader.secondsSinceSeen)) ago "
                              + "· asleep or in case"))
        }
        menu.addItem(.separator())

        let s = Analyzer.summarize(reader.loadSamples())

        // Live estimate for the charge you're on right now.
        if let c = s.current {
            menu.addItem(info(String(format: "Draining %.1f%%/hour (this charge)",
                                     c.rate)))
        }
        if let h = s.hoursToEmpty() {
            menu.addItem(info("Time to empty: \(fmtHours(h))"))
        }

        // Lifetime history, pooled across every logged charge cycle.
        if let full = s.avgFullRuntime() {
            let n = s.cycleCount
            menu.addItem(info("Full charge lasts ~\(fmtHours(full)) "
                              + "(avg of \(n) cycle\(n == 1 ? "" : "s"))"))
        }

        if s.current == nil && s.avgRate == nil {
            menu.addItem(info("Runtime: gathering data…"))
            menu.addItem(info("(needs a bit of discharge history)"))
        }

        if let since = s.trackingSince {
            let df = DateFormatter(); df.dateFormat = "MMM d"
            menu.addItem(info("Tracked since \(df.string(from: since)) · "
                              + "\(s.sampleCount) readings"))
        }

        menu.addItem(.separator())
        let logItem = NSMenuItem(title: "Open battery log (CSV)",
                                 action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)
        let resetItem = NSMenuItem(title: "Reset history…",
                                   action: #selector(resetHistory), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)
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

    @objc private func resetHistory() {
        let alert = NSAlert()
        alert.messageText = "Reset battery history?"
        alert.informativeText = "The runtime estimate and the CSV log will start "
            + "fresh. Your existing data is moved to a timestamped backup next to "
            + "the log (battery_log.<date>.csv), not deleted."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        reader.archiveLog()
        render(reader.lastPct)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
app.run()
