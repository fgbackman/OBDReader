# OBD Reader — project handoff

A context note to hand an AI assistant (or a developer) so work can continue without
re-explaining. Paste it in at the start of a new session, with the OBDReader.zip attached.

---

## 1. What this is

A native **macOS SwiftUI** app that reads a car's diagnostics through a **USB ELM327-compatible
OBD-II adapter**. It is **read-only** apart from a user-confirmed "clear codes" (OBD Mode 04).
Working name for a branded version: **Dips Deep Scanner** (a proposal to a YouTuber; don't use
that name publicly without his agreement).

- Language/UI: Swift 5.9, SwiftUI, Charts, AppKit. Target macOS 14+.
- Package: SwiftPM, a single `executableTarget` named `OBDReader` at `Sources/OBDReader/`.
- Owner works on a MacBook and an M4 Mac mini. The app has **never run on a real car yet** —
  all testing to date is against the built-in simulator. It builds and runs on the owner's MacBook
  (Swift 6.3, Command Line Tools, Swift 5 language mode) and installs to /Applications with a Dock
  icon and menu-bar gauge. The cable the owner first tried was a VW "VCP" FT245R cable, which is
  not ELM327 and can't work with this app — an OBDLink EX or vLinker FS USB is needed.

## 2. Hardware it targets

- **ELM327-compatible USB adapters only.** Designed for the **OBDLink EX** (STN2230 chip) and the
  **Vgate vLinker FS** (ELM327-compatible). Both use FTDI USB chips → appear on macOS as
  `/dev/cu.usbserial-*`, no driver install.
- Standard AT command set only (`ATZ/ATE0/ATS0/ATH1/ATSP0/ATDPN/ATRV/ATPC`), plus reading the
  STN chip id. No SocketCAN, no J2534, no custom CAN transceiver, no Bluetooth.
- Optional second device: a **USB NMEA GPS receiver** (any; 5–10 Hz best) for speed above the
  OBD-II 158 mph ceiling.

## 3. OBD services used (what it speaks today)

Standard SAE J1979 only:

| Service | Use |
|---|---|
| Mode 01 | Live sensor PIDs, readiness monitors (PID 01), MIL status |
| Mode 02 | Freeze frame |
| Mode 03 / 07 / 0A | Stored / pending / permanent DTCs |
| Mode 04 | Clear codes (only after explicit user confirmation) |
| Mode 06 | On-board self-test results with limits (CAN cars) |
| Mode 09 | VIN, calibration IDs, ECU name |
| `ATRV` | Battery voltage (adapter command, not a bus request) |

**It does NOT send UDS (ISO 14229) or KWP2000 manufacturer requests, does not probe module
addresses, and does no security access, coding, or key programming.** That boundary is
intentional (see §8).

## 4. File map (`Sources/OBDReader/`, ~4,500 lines, 15 files)

| File | Responsibility |
|---|---|
| `Transport.swift` | `Transport` protocol; `SerialTransport` (POSIX termios, 115200 baud, port discovery); `SimulatedTransport` lives in Simulator.swift |
| `ELM327.swift` | Adapter setup, request/response, error checks, CAN ISO-TP reassembly (`parseCAN`), legacy K-line parse (`parseLegacy`), fast multi-PID read (`readPIDs`), `ECUMessage` type, `enginePreferred`, hex helpers |
| `PIDs.swift` | Mode 01 PID table (`PIDDef`: decode closure, units, bytes), unit conversion, `PIDs.supported` bitmap decode, `Readiness` struct + `Readiness.combined` (multi-ECU merge) |
| `DTC.swift` | DTC decode (J2012), `DTCDatabase` description table + pattern rules, Mode 03/07/0A parse |
| `Mode06.swift` | `TestResult` (incl. `ecu`, `bankOffset`), `Mode06.parse`, monitor/test names, unit-and-scaling-ID table |
| `Diagnosis.swift` | Rule engine: codes + self-tests + live data → ranked `Finding`s (misfire, lean/rich, catalyst, EVAP, cooling, charging, comms, readiness, cyl 13–16 group) |
| `Garage.swift` | `CarProfile`, `AlertRule`, `ScanRecord`; `GarageStore` (JSON persistence); `VINDecoder` (model year from VIN pos 10, WMI→make) |
| `Drive.swift` | `SpeedEstimator` (RPM→speed), `TripComputer`, `PerformanceTimer` (0–60 / ¼ mile), `AlertMonitor` |
| `GPS.swift` | `GPSReceiver`: termios serial read on a background Thread, NMEA parse (VTG/RMC/GGA) |
| `Reports.swift` | `SmogVerdict` (California BAR rules), `CrankResult`, `PDFExporter` (markdown→PDF via NSTextView/NSPrintOperation), `AIExplainer` (Anthropic API), `Keychain` |
| `VehicleSession.swift` | **The brain.** `@MainActor ObservableObject`: connection, scan sequence, live loop, speed-source selection, GPS, battery test, recording, report, all `@Published` state |
| `App.swift` | `@main`, `MenuBarExtra`, sidebar sections, routing |
| `Views.swift` | Connection, Dashboard, Codes, Diagnosis, Readiness, Vehicle Info, Log views + shared `Card`/`PageHeader` |
| `FeatureViews.swift` | Self-Tests, Smog, Battery Test, History, AI, Garage, Trip, Performance, Alerts views, menu-bar content |
| `Inspection.swift` | `SoftwareID` (CALID + CVN per ECU), `Mode09` payload/CALID/CVN parsing, `PrePurchaseReport.build` rules |
| `Replay.swift` | `Recording`/`Exchange` (Codable), `RecordingTransport`, `ReplayTransport` (re-synthesises Mode 01 for any PID mix), `ISOTP.lines` |
| `ExoticViews.swift` | Pre-Purchase Check, Turbo & Torque, Track views; `GMeter`, `TrackMap` |
| `Simulator.swift` | `SimulatedTransport`: a fake W16 car — two engine ECUs (7E8 cyl 1–8, 7E9 cyl 9–16), drive cycle, self-tests, cranking scenario |

Data persists in `~/Library/Application Support/OBDReader/` (`garage.json`, `history/<vin>.json`).
API key in the macOS Keychain (service `OBDReader`).

## 5. Key design points

- **Serial I/O off the main thread.** `VehicleSession.io { elm in ... }` hops to a serial
  `DispatchQueue` via `withCheckedThrowingContinuation`; all `@Published` mutation stays on
  `@MainActor`.
- **Multi-ECU everywhere.** Readiness, DTCs and Mode 06 self-tests are read from *every* module
  that answers, not just the engine. This is required for correctness (smog) and for the W16.
- **Fast live data.** `ELM327.readPIDs` batches up to 6 PIDs per CAN request (e.g. `010C0D0510`)
  and uses the "expect N responses" trailing digit; it auto-falls-back to one-at-a-time.
- **Speed source selection** (in `sampleOnce`): GPS (if fresh) > RPM estimate (once OBD speed
  pegs at 254+ km/h) > OBD. The estimator learns top-gear rpm/speed ratio while OBD speed is
  still valid.
- **Simulator fidelity matters.** Every feature is demoed in `SimulatedTransport`; keep it in
  sync when adding features, or pages look empty in demo mode.

## 6. What's built (feature list)

Diagnose: Diagnosis (plain-English ranked findings) · Trouble Codes (stored/pending/permanent +
freeze frame, confirmed clear) · Self-Tests (Mode 06 with pass/fail limits, "near limit",
per-cylinder misfire chart) · Readiness · **Smog Check** (California BAR OBD rules) · **Battery
Test** (resting/cranking/charging, charted) · History (per-VIN, trend charts, code timeline) ·
**AI Explanation** (Anthropic API, own key, VIN optional).

Drive: Live Dashboard (multi-PID, sparklines, CSV) · Trip computer · Performance (0–60 / ¼ mile,
GPS or estimate) · Alerts (per-car thresholds, sound + notification) · Menu-bar gauge.

Car: Garage profiles by VIN · PDF/Markdown report export.

## 7. Phase 0 (W16 / limits) — DONE in current build

- **Readiness merged across all ECUs** (`Readiness.combined`): a monitor is not-ready if any
  module reports it incomplete; MIL = any; code count = sum. (Was a bug: engine-only.)
- **Self-tests read from all engine ECUs** (`readTests` rewrite): a W16's second computer gives
  cylinders 9–16; the second ECU gets `bankOffset = 8` so its cyl 1 shows as cyl 9.
- **Cylinders beyond 12, grouped** (Diagnosis): if a 16-cyl total (MID A1 TID 0C) exceeds the
  sum of named cylinders 1–12, report the remainder as a group.
- **Speed past 158 mph**: `GPSReceiver` (NMEA USB) + `SpeedEstimator` (RPM × learned top-gear
  ratio when OBD speed saturates). UI on Connection + a source indicator on Dashboard.

Verified by mirroring the logic in Python against simulator data (merge, bank offset, group
count, estimate). A review pass found/fixed a key-path-into-tuple compile error.

## 7b. Exotic-car round — DONE in current build

- **Pre-purchase check** (`Inspection.swift`, Diagnose → Pre-Purchase Check): recently-cleared detection
  (PIDs 30/31/4E: red if < 5 warm-ups or < 80 km), incomplete monitors, permanent/stored/pending codes,
  distance & time with MIL on (21/4D), ECU odometer (A6) vs user-entered dash reading and vs the last scan,
  VIN mismatch across ECUs (0902 from every module), software change vs last scan.
- **Tune detection:** Mode 09 04 (CALID) + 06 (CVN) read per ECU, saved in every `ScanRecord`
  (`software`, `vins`, `odometerKm` are optional fields so old history files still decode).
- **Multi-sensor PIDs:** `PIDDef.channels` (`PIDChannel`) for 6F, 74, 75, 76, 78, 79, 87; headline value can be
  NaN and is skipped; channel values live in `VehicleSession.extValues/extHistory`. Also 03, 3E/3F, 44, 4D, 4E,
  51, 5D, 61–63, A6 and wideband O2 24–2B / 34–3B. `onDashboard = false` hides status/multi PIDs from pickers.
- **Closed-loop gating:** Diagnosis ignores trim-based lean/rich when PID 03 says open loop; flags "open loop
  due to fault" (8) and "closed loop with fault" (16). Smog auto-detects diesel from PID 51.
- **Engine layout** (`CarProfile.engineLayout`, Garage picker, VF9 → W16 guess). Mode 06 bank offsets are now
  data-driven (cumulative max cylinder per engine ECU, capped by cylinders ÷ ECUs when the layout is known);
  the beyond-12 group rule only runs when the engine can have > 12 cylinders.
- **Battery-drain watch:** idle task every 20 s, warns < 12.0 V, at most every 5 min.
- **Track:** `TrackSession` (closest-approach lap gate 25 m, min lap 20 s, g-long from Δspeed, g-lat from
  v·Δheading, CSV). GPS `Reading` now carries lat/lon/course/fixTime.
- **Record & replay:** see `Replay.swift`; recordings in Application Support/OBDReader/recordings.
- **Simulator:** supported-PID bitmaps are generated from `SimulatedTransport.supported`; demo car shows a
  recent code clear (3 warm-ups, 29 km), two ECUs' CALIDs/CVNs, turbo/EGT/torque/wideband data.
- **CI:** `.github/workflows/build.yml` (macos-15, `swift build -c release`, then `make_app.sh`, uploads the .app).

## 7c. All-cars round — DONE in current build (untested on a real car)

- `PIDs.swift`: added 12, 1C, 1E, 2D, 32, 48, 4B, 53–59, 5B, 67, 7F, A2, A4, A9 (formulas per the SAE J1979
  table on Wikipedia's OBD-II PIDs page; 70/72/73/77 left out because their layouts weren't verified).
- `StandardExtras.swift`: PID 41 drive-cycle monitors, Service 09/08 in-use performance (counter names in J1979
  order — verify), legacy (non-CAN) Service 06 parsing `[46 TID CID V V L L]`, CID bit 7 = min limit.
- `CustomPID.swift`: user-defined reads, formula engine (A–Z bytes, + - * / % & | << >>, signed/signed16/bit/
  min/max/abs, `{A:3}`), JSON/CSV import-export, `ELM327.requestTo(header:)` (ATSH/ATCP + flow control, then
  restores 7DF / 18DB33F1). Services restricted to 01/21/22.
- `ModuleScan.swift`: UDS 19 02 FF per module address (responders + 7E0–7E7 + per-car extras), status-bit
  decoding, ISO 14229 identification DIDs. No 14 (clear), 2E (write), 27 (security) or 31 (routines).
- `ImportedLog.swift`: VCDS CSV importer (tolerant parser; tune on a real file).
- Simulator answers ATSH-addressed 1902FF, 22F190/F187/F189 and a demo 221001 oil-pressure DID.
- Scope decision (owner, Oct 2026): app is for all cars; manufacturer data is read-only. Writing, coding,
  security access and key work remain out.

## 8. Roadmap and the scope boundary

- **Phase 0 (done):** the four items above.
- **Phase 1–2 (Bugatti UDS): intentionally NOT built.** Reading Bugatti's own module codes/DIDs
  needs UDS over ISO-TP with manufacturer security access (seed/key) and secret algorithms the
  ELM327 can't reliably do. Decision: **keep this app standard-OBD-II only**; for VW-group
  dealer-level work use a VAG tool (VCDS / OBDeleven) or the factory tool. If a future owner
  wants to cross that line anyway, references worth studying: `Swift-UDS`, `vinfast-diagnostics`
  (ELM327 UDS), and `ELM327-emulator` for testing. Expect weeks–months and uncertain success.
- **Candidate next features (standard OBD, high value):** pre-purchase inspection mode (detect
  recently-cleared codes via warm-ups/distance-since-clear, incomplete monitors, permanent
  codes, software fingerprint changes, odometer); record & replay of a real car's session
  (owner is in CA, collaborator in UK) to develop against captured data; wideband O2 PIDs
  (0x24–0x3B); fuel-system-status (closed-loop) gating before judging fuel trims; auto fuel-type
  from Mode 01; a CI build on GitHub's macOS runners to catch compile errors.

## 9. Build & run

```bash
cd OBDReader
swift run            # from Terminal, or
./make_app.sh        # builds "OBD Reader.app" (ad-hoc signed)
```
Or open `Package.swift` in Xcode. Needs macOS 14 + Xcode/CLT. Tick **Use simulator** on the
Connection page to try everything with no hardware. Notifications for Alerts need the .app build.

## 10. Known limitations / gotchas

- OBD vehicle speed (PID 0x0D) is one byte → 255 km/h (158 mph) ceiling; GPS/RPM estimate works
  around it.
- Standard per-cylinder misfire counters only name cylinders 1–12; 13–16 need the second ECU or
  the group-count estimate.
- Mode 06 only parsed for CAN cars (older protocols use a different format — not implemented).
- SmogVerdict uses California BAR rules; other states differ. Model year comes from the VIN and
  can be wrong (the 30-year code cycle) — editable in Garage.


## Brand module lists and Nearby (Oct 2026)

- **All Modules → Brand list**: verified request/reply addresses for VAG, Toyota/Lexus, GM, Ford, Hyundai/Kia, Stellantis, Honda, Nissan, Subaru, Mazda and BMW/MINI (experimental extended addressing). Guessed from the profile's make. Sources: opendbc (commaai/opendbc car/<brand>/values.py), OBDb signalsets, OVMS vweup_obd.h, FORScan forum, ISO 15765-4:2005. Bugatti/Ferrari: no public source.
- Address spec format (module scan and Custom Readings): `7E0`, `713>77D` (reply address), `6F1/12>612` (extended address byte), `18DA28F1` (29-bit). `requestTo` now sets ATCRA to the reply address (the ELM327's automatic filter only passes 7E8–7EF), ATCEA for extended addressing, and restores both afterwards. 29-bit addresses are skipped on 11-bit cars and vice versa.
- **Nearby Shops & DMV** (Car section): Apple Maps search (free) or Google Places API (New) Text Search with the user's own key (adds star ratings; Enterprise SKU). Labour rates are user-entered quotes saved in UserDefaults (`shopRates`) because no public data source lists them. DMV tab: California DMV, Florida county tax collectors (FLHSMV), UK (DVLA offices closed 2013; Post Office; DVSA MOT station list; MOT history).


## Our own Auto-Scan (Oct 2026)

- **All Modules → Auto-Scan**: address sweep (22 F190 to every 11-bit 700–7FF, or 29-bit 18DAxxF1; skips 7DF, 7E8–7EF and any reply ID already seen), reads 22 F197 system names, then scans every known module for codes (19 02 FF) and IDs, saves the module list to our library, and exports a plain-text report. Read-only throughout.
- Sweep listens with ATCF400/ATCM400 (11-bit 400–7FF) or ATCF18DAF100/ATCM1FFFFF00 (29-bit), and only accepts 62 F1 90 / 7F 22 replies. Restores with ATFCSM0, ATCRA, ATAR.
- **Module library** (ModuleSweep.swift): Application Support/OBDReader/module-library.json, keyed by make+model, also matched by first 8 VIN characters. Export/import `.obdmodules` JSON.
- Simulator has a VW-style ABS at 713>77D with F197 names.


## VW TP2.0 (Oct 2026) — older VW-group modules

- First real car (2009 Jetta) answered standard OBD-II but nothing on UDS: its ABS/airbag/etc. use VW TP2.0 + KWP2000.
- TP20.swift: raw CAN (ATCAF0, ATAT0, ATST19 for setup / ATST7D for data). Channel setup on 0x200 `[addr C0 00 10 00 03 01]`, reply from 0x200+addr `[00 D0 rxLo rxHi txLo txHi 01]`; tester receives on bytes 2–3 ID, transmits on bytes 4–5 ID. Params A0 0F 8A FF 32 FF. Data opcodes 0/1/2/3, ACK B_, A3 channel test (used to re-listen), A8 disconnect. Reference: icanhack.nl/knowledge-base/diagnostics/vw-tp20, jazdw.net/tp20.
- Per module: 10 89 (VW standard diagnostic session, temporary), 1A 9B (identification), 18 02 FF 00 (fault codes; falls back to 18 00 FF 00). Addresses 01–7F; 25 (immobilizer) never contacted. Restores ATST32, ATAT1, ATCAF1, ATCRA, ATAR, ATSH7DF.
- Fault codes are shown as the 2-byte number in decimal (5 digits). Expected to match VCDS's VAG code numbers — UNVERIFIED until tested on the Jetta. Status byte shown raw.
- Auto-Scan runs TP2.0 too when the brand list is VW group. Simulator implements TP2.0 modules 01, 03 (demo fault 00283), 15 (demo fault 01410), 17, 19.
- UNTESTED on hardware: listening gaps between serial commands may drop packets on slow modules.


## Measuring blocks, drive-cycle coach, module-fault rules, code causes (Oct 2026)

- **Measuring Blocks page** (MeasuringBlocks.swift, sidebar under Diagnose): TP2.0 channel → 10 89 → `21 <group>` (read-only service 21). Reply `61 <group>` + fields; most are [type, A, B]; 0x3F text to end, 0x5F/0x76 length-prefixed, 0xA0 6 bytes (raw). Trailing `25 00 00` cells trimmed. Up to 3 groups, Read once / Go live / Stop, min/max, CSV log export.
  - Formulas: types 01–46 from gmenounos/kw1281test Blocks/SensorValue.cs (blafusel-based); 47–5E and the 60+ subset from domnulvlad/KLineKWP1281Lib. Sources disagree on 0x10, 0x19, 0x27, 0x42, 0x51, 0x5E — verify on a real car. Unknown types show raw bytes.
- **Drive-cycle coach** (StandardExtras.swift, on Readiness): per-monitor driving tips + a general drive pattern; marks monitors that finished this drive (PID 41). General guidance — exact cycles are manufacturer-specific.
- **Diagnosis rules** (Diagnosis.swift): "Faults stored in N other modules" (ABS/airbag checks) from All Modules + TP2.0 results (engine addresses excluded); "Low voltage with faults in several modules" when battery < 12.4 V and ≥2 modules or ≥2 U-codes.
- **DTC common causes** (DTC.swift `DTCDatabase.causes`): our own wording, ~60 codes + patterned misfire/injector/coil/O2 ranges; shown on Trouble Codes, All Modules and reports. Added ~59 SAE titles from the AutoNation VW code list (their prose not copied).
- Simulator: TP2.0 module 02 group 4 (59 °C, ~51/53 bar oil pressures) and module 01 group 1 (rpm, coolant, lambda, mbar).


## OBDb importer (Oct 2026)

- OBDb.swift: imports OBDb signalsets (github.com/OBDb/<Make-Model>/signalsets/v3/default.json, CC BY-SA 4.0) into Custom Readings. "Get from OBDb" downloads by Garage make/model (raw.githubusercontent.com, branch main); Import… also accepts a downloaded signalset JSON.
- Mapping: hdr/rax/eax → our spec (`713>77D`, `6F1/12>612`); 29-bit = pri+hdr+tst, rax 6 digits = pri+rax, 8 digits = full (commands with a custom rax but no pri/tst are skipped). Services 01/21/22 only; commands with `din` (need a diagnostic session) skipped; other-bus commands skipped when connected; year `filter` honoured (to<from means "≤to or ≥from").
- Signals become CustomPIDs with `bits: BitField` (bix from first data byte after the echo, MSB-first; blsb = little-endian bytes; sign; mul/div/add; nullmin/nullmax → "not available"; map → text, keyed by raw value; on/off & yes/no units mapped). Imported readings start disabled; search + Enable/Disable shown. One request per module+identifier per pass (failures cached too). CSV export skips bit-field readings (use JSON).
- Credit line shown on cards and the page (CC BY-SA attribution).


## VW fault-code text (Oct 2026)

- TP20.swift `VAGCodes`: engine faults map to P-codes by offset — 16384 for P0xxx (16684 = P0300), 16408 for P1xxx (17965 = P1557); confirmed by vag-coding.net and stedmansgarage.co.uk tables. P0 codes reuse DTCDatabase titles + common causes; P1 shown as VW-specific.
- ~24 common non-engine VW codes named in our wording (ABS wheel-speed sensors 00283/00285/00287/00290, airbag igniters, steering angle sensor 00778, supply voltage 00532/00668, coding 01042/01044, no-communication 01314/01316…) with causes. Unknown numbers say to look them up in VW repair information.


## Wheel Speed Test (Oct 2026)

- WheelSpeed.swift, sidebar "Wheel Speed Test" (Diagnose). Read-only comparison of the four ABS wheel-speed sensors while driving.
- Sources: VW-group TP2.0 ABS module 03 measuring block (default group 001; fields with km/h, assumed FL/FR/RL/RR) via readBlocks live; or enabled Custom Readings named "wheel … speed" (OBDb imports) via custom live.
- WheelAnalyzer: judged only when median ≥ 10 km/h; dropout = <2 km/h while moving; "off" = >5 % from median above 20 km/h. Bad if >50 % dropouts or ≥3 dropouts; suspect if >30 % off or any dropout. Needs ≥20 moving samples.
- Simulator: module 03 group 1 = four speeds, rear-left drops out every 7 s. Diagnosis ABS finding now suggests the test.


## Module IDs, VIN check, block explorer, stored mileage (Oct 2026)

- UDS identification now also reads F18A supplier, F18B manufacturing date, F192–F195 supplier hardware/software numbers and versions (all F1xx, read-only).
- Module cards flag a module VIN (F190) that differs from the car's VIN; module VINs also feed the Pre-Purchase "VIN across modules" check.
- Measuring Blocks → "Explore a module": reads groups 001–040 once on 17 (instruments), 19 (gateway), 03 (ABS) or the selected module and lists every non-empty group. Fields in km above 100 are recorded as stored mileage and compared with the ECU/dash odometer on the Pre-Purchase Check (red if off by more than max(500 km, 5 %)).
- Simulator: 17 group 002 = 123,450 km; 19 group 001 = 12.2 V, 75 %.


## Gateway list, cam timing, diesel PIDs (Oct 2026)

- VWChecks.swift (on Measuring Blocks): **Gateway installation list** = explore module 19 groups 125–129; text fields ending " 0" listed as not communicating (format varies by gateway — raw groups shown). **Camshaft timing** = explore engine 01 groups 1–130 and list every °KW field; baseline saved per VIN in UserDefaults (`camBaseline.<VIN>`), change shown on later runs. Group numbers not hard-coded.
- exploreBlocks(address:first:last:) now takes a range; explorer has a Stop button; `explorerAddress` published.
- PIDs: 0x7C DPF temperatures (support byte + four (256A+B)/10−40 °C; layout assumed like 78/79 — verify), 0x85 DEF/AdBlue tank level (byte F ×100/255 %). Both from Wikipedia OBD-II PIDs; 7A/7B/83/8B not added (encodings not confirmed).
- Simulator: 01 group 093 (−2.5/−3.1 °KW), 19 groups 125/126 (Radio 0 = not talking demo).


## Interpretation fixes (Oct 2026)

- **Failure type byte** (FailureType.swift): SAE J2012 / ISO 15031-6 FTB meanings (≈90 values, each confirmed by ≥2 sources: Volvo Trucks SI, JLR IDS indexes, Ford workshop manuals, Ford/TRW NHTSA filing). Shown as "How it failed" on All Modules cards and in reports. GM makes are NOT translated (GM uses its own symptom byte). 0xF0–0xFF = manufacturer-specific; unknown = "unlisted".
- **Sensor ranges** (PIDs 4F/50): read during the scan and shown on Vehicle Info. The app still decodes wideband O2 / MAP / MAF with the default ranges (λ 2, 8 V, 128 mA, 255 kPa, 655.35 g/s); if the car reports different maxima, a warning says those readings may be scaled differently (rescaling formula not verified, so not applied).
- **More standard PIDs** (formulas from Wikipedia OBD-II PIDs): 64 engine percent torque points, 66 MAF sensors A/B, 68 IAT sensors 1/2, 8E friction torque, A5 commanded DEF dosing. Still not decoded (no published formula): 69–6E, 71, 7A/7B, 7D/7E, 81–84, 86, 88, 8B–8D, 8F, 94, 9A–9F, A1, A3, A7, A8.
- **Measuring-block field names**: pencil on each field → name it (e.g. "Oil pressure"). Saved per car (CarProfile.blockLabels, key "AA.GGG.F") and in the module library for the make/model (LibraryModel.blockLabels), so exports/imports share them. Used in CSV headers.


## Cross-check against CSS Electronics OBD2 DBC v4.3 (Oct 2026)

- Fred supplied CSS Electronics' OBD2 DBC (obd-dbc-files-v4.3.zip). Audit of ~150 Mode 01 signals vs PIDs.swift: all match except PID 54 (evap vapor pressure wide range) — fixed to (256A+B) − 32767 Pa (Wikipedia + CSS agree). PID 32 kept signed (CSS min −8192 confirms signed despite its "+" flag).
- Not decoded yet but in the DBC: O2 short-term trim byte B of 14–1B and 55–58 (B × 0.78125 − 100 %), wideband O2 voltage/current C–D of 24–2B / 34–3B.
- The DBC lists next-gen OBD (WWH-OBD / J1979-2) DIDs 22 F4xx with byte layouts identical to Mode 01 PIDs (157/157 identical) — so OBD-on-UDS live data can reuse the existing decoders.
- The DBC has no formulas for the ~50 still-undecoded PIDs (only raw byte placeholders for 65, 69–6E).

## CAN Bus Listener (Oct 2026)

Files: DBC.swift (CANKey/CANFrame, DBCSignal/DBCMessage/DBCFile parser + decoder, DBCLibrary, BusStat, BusLogFile, WarningSignals), BusListener.swift (page), Transport.monitor (protocol requirement with a throwing default; SerialTransport, SimulatedTransport, RecordingTransport implement it), ELM327.listenBegin/listenWindow/listenEnd, VehicleSession "CAN bus listener" section, App sidebar .bus. Fred approved passive listening on 2026-10-15 ("go on brand dbc"). Still read-only: monitor mode only.
Test status: decoder logic checked in Python against cantools; Swift not yet compiled when this was written — build and test in the simulator (Start listening → pick vw_golf_mk4.dbc → Bremse_1 shows Lampe_ABS = 1).
Next ideas: feed Bremse_3-style wheel speeds into the Wheel Speed Test; chart a pinned signal.

## Connection options, OBD on UDS, O2 channels (Oct 17 2026)

Built and tested in the simulator on 2026-10-17 (STATUS=success, no new warnings):
- Listen-only connect + CAN Bus Listener: 6 IDs at expected rates, vw_golf_mk4.dbc decodes all 6, "Which DBC fits" = 6 of 6, warning-light view shows Lampe_ABS = 1 and Lampe_ASR___ESP = 1. Adapter log during the whole listen-only session: AT/ST commands only; Rescan sent nothing.
- Normal connect after that: full scan, codes and Diagnosis as before.
- Not yet tested: OBD on UDS (SAE J1979-2) — the simulator doesn't emulate it; needs a 2027-ish car. Ford MS-CAN protocol B needs a Ford/Mazda and cable A.
- Note: section 8's "standard OBD-II only" line is out of date; Fred has since approved the read-only manufacturer reads listed in README and passive listening.
