# AirPods Max Battery

A tiny macOS menu-bar app that shows your **AirPods Max** battery level, logs it
over time, and estimates how long a full charge actually lasts — using nothing
but public CoreBluetooth. No private frameworks, no network, no dependencies.

```
🎧 43%
────────────────────────────
AirPods Max — 43%
Draining 4.8%/hour (this charge)
Time to empty: 8h 57m
Full charge lasts ~20h 50m (avg of 6 cycles)
Tracked since Jul 8 · 412 readings
────────────────────────────
Open battery log (CSV)
Reset history…
Quit
```

The runtime figure is pooled across **every** logged charge cycle, so it keeps
improving over time instead of resetting each time you charge. **Reset history…**
archives the log to a timestamped backup (`battery_log.<date>.csv`, never
deleted) and starts fresh.

The Max stop broadcasting when they're in the case or off your head, so once no
advertisement has arrived for a few minutes the reading is shown as `🎧 ~85%`
(the `~` means "last known", not live) with a "Last seen … ago" note in the
menu — rather than pretending the stale number is current.

## Why this exists

macOS does **not** expose the AirPods Max battery to any command-line tool —
`ioreg`, `system_profiler`, and the `com.apple.Bluetooth` plist all come up
empty (the lone `BatteryPercent` in `ioreg` belongs to the Magic Keyboard, not
the headphones). Control Center reads it over a private path.

It turns out the exact number is sitting in the **Apple "proximity pairing" BLE
advertisement** that the Max continuously broadcast:

```
manufacturer data (29 bytes):
4c 00 | 07 19 01 1f 20 2b 04 80 03 55 29 09 26 ...
company │  │  │  │model │              └ idx14 = 0x26 = 38%  ← the real battery
0x004C  │  │  │  0x201f └ idx7 = status/wear flag (NOT battery)
        │  │  └ prefix (0x01)
        │  └ length (0x19)
        └ type 0x07 (proximity pairing)
```

The battery is a plain `0–100` byte at **index 14** — full 1% resolution, and it
matches Control Center / the iPhone reading. The decoder filters on company
`0x004C`, message type `0x07`, and model `0x201f`, so it only ever reports
*your* AirPods Max and ignores every other nearby device.

### Gotcha: byte 7 is a decoy

Byte **7** *looks* like battery and will fool you — during one calibration it
read `0x2b` = 43 while the battery genuinely was 43%. But it's a **status/wear
flag**: it freezes while the number drifts, and drops to `0x01` when you take the
Max off your head. If you calibrate against a single reading you can pick it by
accident. Byte **14** is the one that actually tracks discharge 1% at a time.
The `probe/` sources document how this was found (dump the full packet at two
different battery levels and diff — only the true battery byte moves *with* the
level).

### What is *not* reachable

The exact value the OS shows also travels over the connected link via Apple's
accessory protocol (AAP, L2CAP PSM `0x1001`), but macOS blocks third-party
processes from opening that channel (`kIOReturnError`) and gates the private
`BluetoothManager` framework behind an entitlement. The BLE advertisement above
is the only public source — and, once you read the right byte, it's exact.

> Note: `0x201f` is the **USB-C (2024)** AirPods Max. The original Lightning
> model has a different model ID — adding it is a one-line change to the filter.

## Build

Requires the Xcode Command Line Tools (`xcode-select --install`) — full Xcode
is **not** needed.

```sh
./build.sh
```

This compiles `src/main.swift`, assembles `AirPodsMaxBattery.app`, and ad-hoc
signs it (needed so macOS will show the Bluetooth permission prompt).

## Run

```sh
open ./AirPodsMaxBattery.app
```

On first launch, click **Allow** on the "wants to use Bluetooth" prompt. The
menu-bar icon appears as `🎧 nn%`. Battery readings are appended to
`~/airpods-max-battery/battery_log.csv`.

### Auto-start on login (optional)

A `LaunchAgent` keeps the logger running continuously (and restarts it if it
dies) so it can measure a full charge cycle:

```sh
cp com.airpodsmaxbattery.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.airpodsmaxbattery.plist
```

To remove it:

```sh
launchctl unload ~/Library/LaunchAgents/com.airpodsmaxbattery.plist
rm ~/Library/LaunchAgents/com.airpodsmaxbattery.plist
```

## Runtime report

After using the headphones for a while:

```sh
python3 report.py
```

Prints an ASCII discharge curve per charge cycle and the measured
"a full charge lasts ~Xh" figure. Pure stdlib — no matplotlib required.

## Security notes

- **No network.** The binary links only AppKit, CoreBluetooth, and Foundation;
  there are no `URLSession`/socket/HTTP calls. Data cannot leave your machine.
- **Read-only Bluetooth.** It passively listens for advertisements — it never
  connects to, pairs with, or writes to any device.
- **No third-party code**, no shell-outs, no private frameworks.
- It runs as your user (a LaunchAgent, not a root daemon) and stores only
  battery % + timestamps locally.
- The one broad capability is the Bluetooth permission itself, which lets any
  such app see all nearby BLE devices — this is inherent to the platform, not
  specific to this tool.

## Layout

```
src/main.swift    the menu-bar app (CoreBluetooth reader + logger + estimator)
build.sh          compile + assemble + ad-hoc sign the .app
report.py         discharge-curve / runtime report over the CSV
probe/probe.swift throwaway BLE dumper used to discover the advertisement layout
probe/verify.swift throwaway validator that confirmed byte[7] == battery %
```

## License

MIT
