# OBD Reader for macOS

A native SwiftUI app that reads a car's standard OBD-II diagnostics through a USB adapter.
Read-only by design: the only thing it ever changes in the car is clearing codes (Mode 04),
and only after you confirm. A built-in simulator lets you try everything without a car.

**Diagnose**
- **Diagnosis** — plain-English findings ranked by urgency, built from codes, self-tests and live data
  (fuel trims are only judged when the engine is in closed loop, so cold starts and full throttle don't cause false alarms)
- **Pre-Purchase Check** — for a used car you're viewing: codes wiped just before the viewing (warm-ups / distance /
  time since clear), unfinished monitors, permanent codes a scanner can't erase, distance driven with the light on,
  ECU odometer vs the dashboard, VIN mismatches between modules, and the engine-software fingerprint
  (calibration ID + checksum per module) with a warning if it changed since the last scan — a tune or a re-flash
- **Trouble Codes** — stored, pending and permanent, with descriptions and freeze frame; clear with confirmation
- **Self-Tests** — the car's own monitor test results (Mode 06) with pass/fail limits, "close to the limit"
  warnings, and per-cylinder misfire counters
- **Readiness** and **Smog Check** — predicts the OBD part of a California Smog Check using BAR's rules
- **Battery Test** — resting voltage, cranking dip and charging voltage, charted
- **History** — every scan saved per car; trend charts and a code timeline
- **AI Explanation** — sends the report to Claude (your own API key, stored in Keychain; VIN optional)

**Drive**
- **Live Dashboard** — multi-sensor requests (several times faster on CAN cars), sparklines, CSV recording
- **Turbo & Torque** — boost per bank, turbo speed and temperatures, exhaust-gas temps per sensor, driver-demand vs
  actual torque, estimated torque and power, closed/open-loop status and wideband λ per bank (on cars that report them)
- **Track** — GPS lap timer with a start/finish you set, g-meter (braking/accel from speed, cornering from GPS
  heading), track map, lap table, CSV export of every sample
- **Trip** — distance, fuel used, mpg / L/100 km, average and top speed
- **Performance** — 0–60 mph (or 0–100 km/h) and quarter-mile with trap speed (track use only)
- **Speed past 158 mph** — optional USB GPS receiver, plus an RPM-based estimate that learns the car's top-gear ratio when GPS isn't connected
- **Alerts** — sound + notification when a reading crosses your limits (per car)
- **Menu bar gauge** — live readings in the Mac menu bar

**Car** — **Garage** profiles recognised by VIN (nickname, model year, fuel type, engine layout,
dashboard layout, alerts, menu-bar readings). Reports export as **PDF** or Markdown.

**Every car, beyond the basics**
- **All standard readings** — the full SAE J1979 set the app knows (adds e.g. total engine hours, transmission gear
  ratio, rear O2 trims, evap pressures, OBD standard), "this drive cycle" monitors, in-use performance counters,
  and self-test results on older non-CAN cars
- **All Modules** — fault codes from every module that answers the standard UDS request (19 02 FF), not just
  emissions codes, plus part / software numbers (F187, F189, F190…). Read-only; nothing is cleared or written
- **Custom Readings** — manufacturer data you define (module address + read request + formula), saved per car,
  shareable as `.obdpids` or CSV. Only read services (01, 21, 22) are allowed
- **Imported Logs** — VCDS measuring-block CSVs charted alongside the app's own data
- **Engine Health** — fuel-trim map by RPM × load (closed loop only), catalyst indicator from front/rear O2
  switching, warm-up curve, idle smoothness, and trends across scans (misfires, closest self-test margin,
  idle spread, battery)
- **Recalls & records** (Vehicle Info) — NHTSA recalls by make/model/year for US cars; links to the UK MOT
  history (mileage at each test) and UK recall check
- **Where the car is kept** (Garage) — California / Florida / other US / England; the Smog page explains which
  inspection applies

**Also**
- **Battery-drain watch** — while connected and idle, checks the battery every 20 s and warns below 12.0 V
  (long sessions with the ignition on flatten batteries, and a low battery sets false codes)
- **Record & replay** — tick *Record the next session* on the Connection page; on disconnect the whole
  session is saved (`~/Library/Application Support/OBDReader/recordings/*.obdrec`). *Open recording…*
  replays it on any Mac with every page working as if the car were plugged in
- **Build check** — `.github/workflows/build.yml` compiles the app on GitHub's macOS runners on every push

## Hardware

| Item | Why |
|---|---|
| **OBDLink EX** (USB, STN2230 chip, ~$70) | Fast, reliable ELM327-compatible chip; covers all OBD-II protocols (CAN, KWP2000, ISO 9141, J1850). Its USB chip is FTDI, which macOS supports natively, so it shows up as `/dev/cu.usbserial-…` with no driver install. |
| **USB-C → USB-A adapter** (e.g. Apple's) | The EX cable is USB-A. |

The OBDLink website lists macOS as "not supported" — that refers to *their* Windows/mobile
apps. This app talks to the adapter directly, so that doesn't matter.

Any ELM327-compatible USB adapter works, but cheap clones are often slow or flaky.

## Build & run

Requires macOS 14+ and Xcode (or the Command Line Tools).

```bash
cd OBDReader
swift run                 # quick run from Terminal
./make_app.sh             # or build "OBD Reader.app"
```

Or open `Package.swift` in Xcode and press Run.

## Using it

1. Plug the adapter into the OBD-II port (16-pin socket under the dash, usually the
   driver's side — the owner's manual shows the exact spot), USB into the Mac.
2. Ignition ON. Engine off is fine for codes; start it for live data.
3. Connection → pick `/dev/cu.usbserial-…` → Connect. The app auto-detects the protocol,
   then runs a full scan and opens the Diagnosis page.
4. Export Report (toolbar) saves everything as Markdown.

Tick **Use simulator** to try the app with a pretend car. It has a lean bank, a cylinder-5
misfire, a failing catalyst self-test, loops through a launch-and-brake drive cycle, and
"starts" itself during the battery test — so every page has something on it.

Notifications for alerts need the .app build (`./make_app.sh`); with `swift run` you get
the sound and the in-app banner.

## About Bugatti (and other exotics)

US-market cars since 1996 must answer generic OBD-II requests, so emissions codes, the
check-engine light, readiness, freeze frame, VIN and live engine data read the same way on
a Veyron or Chiron as on any car. Codes from non-emissions systems and anything marked
manufacturer-specific need the factory service tool at an authorised service centre — the
exported report gives them a head start.

### W16-specific handling (standard OBD-II only)

- **All 16 cylinders.** Self-tests, trouble codes and readiness are read from *every* control
  unit that answers, not just the first. A W16 runs on two engine computers; reading both is
  what surfaces misfire counters for cylinders 9–16. The second computer's cylinders are
  numbered 9–16 automatically.
- **Cylinders beyond 12, grouped.** If a car exposes a 16-cylinder misfire total but only names
  12 cylinders, the Diagnosis page reports the remaining count as a group (it can't say which
  one without the factory tool).
- **Speed past 158 mph.** A USB GPS receiver (Connection page) gives true speed with no ceiling;
  without it, an RPM-based estimate kicks in once the OBD speed value saturates, using the
  top-gear ratio it learned earlier in the drive.

This app stays within standard OBD-II. It does **not** send manufacturer UDS/KWP requests, probe
for module addresses, or do security access, coding or key work — that's dealer-tool territory
(for VW-group cars, a VAG-specific scanner or the factory tool).

## Code map

| File | What it does |
|---|---|
| `Transport.swift` | POSIX serial port (termios, 115200 baud) and port discovery |
| `ELM327.swift` | Adapter setup, request/response, CAN ISO-TP reassembly, K-line parsing |
| `PIDs.swift` | Mode 01 sensor definitions, unit conversion, readiness decoding |
| `DTC.swift` | Code decoding and description database |
| `Diagnosis.swift` | Rules that turn codes, self-tests and live data into findings |
| `Mode06.swift` | Self-test (monitor) results: parsing, names, units, limits |
| `Garage.swift` | Car profiles, scan history, VIN model-year decoding |
| `Drive.swift` | Trip computer, performance timer, alerts, RPM-based speed estimator, track session (laps, g) |
| `Inspection.swift` | Pre-purchase check rules, Mode 09 calibration ID / CVN parsing |
| `Replay.swift` | Session recording and replay transports |
| `GPS.swift` | Optional USB NMEA GPS receiver for speed past 158 mph |
| `Reports.swift` | Smog predictor, battery-test verdicts, PDF export, Claude API, Keychain |
| `VehicleSession.swift` | App state, scan sequence, live loop, CSV, report |
| `Simulator.swift` | Fake adapter + car (drive cycle, self-tests, cranking) for testing |
| `App.swift`, `Views.swift`, `FeatureViews.swift`, `ExoticViews.swift` | SwiftUI interface and menu bar |

Data is stored in `~/Library/Application Support/OBDReader/` (garage.json, history/, recordings/).


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

## CAN Bus Listener with DBC files (Oct 2026)

Advanced → CAN Bus Listener. Puts the adapter in monitor mode (ATCSM1 silent monitoring, ATCAF0, ATMA in half-second windows) and decodes what it hears with a DBC file. Listen-only: no message is sent to the car.

- Add DBC files or whole folders (copied to ~/Library/Application Support/OBDReader/DBC). "Which DBC fits this car?" ranks every added file by how many of the heard IDs it describes (and how many also match the frame length).
- Per-ID rate, live bytes (orange = has changed), expandable decoded signals with min–max, value-table text, and an orange flag when a value falls outside the DBC's own range (suggests the file doesn't match the car).
- "Warning lights only" lists lamp/warning signals by name (lamp, light, warn, Lampe, Leuchte, Kontroll …).
- Listen to one ID only (ATCRA) for slow adapters; buffer overflows are counted and reported.
- Save log (time_s,id,extended,data CSV), Open log to decode it again offline with any DBC, Save decoded (one row per signal value). Times are approximate: ELM327 monitor output has no timestamps, so frames are spread evenly over each half-second window.
- Parser verified against cantools on random frames for every message in 60 brand DBC files (477,727 values, 0 differences); it also opens the 19 files cantools rejects. Handles Intel/Motorola, signed, up to 64-bit, multiplexed (M/mN), VAL_, CM_, SystemMessage/SignalLongSymbol, 29-bit IDs written without the extended flag; duplicate IDs keep the first definition.
- Simulator broadcasts VW PQ messages laid out as in vw_golf_mk4.dbc (Motor_1 280, Bremse_1 1A0 with ABS + ESP lamps on, Bremse_3 4A0 with a rear-left dropout, Kombi_1 320, Kombi_2 420) plus one unknown ID 5D0. Checked with cantools.
- Caveats shown in the app: many cars' gateways keep internal traffic off the OBD port; brand DBCs are mostly reverse-engineered (CSS README: "quality may vary"); cheap clones overflow at 500 kbit/s.

## Connection options, OBD on UDS, O2 channels (Oct 2026)

- Connection page: **Protocol** picker (Automatic, CAN 11/29-bit 500/250 kbaud, Ford MS-CAN = ELM327 protocol B, 11-bit 125 kbaud by default, K-line, KWP, J1850) and **Listen only (CAN tap)**. Listen-only sets the protocol with ATSP (CAN 11-bit 500k if Automatic, because the automatic search transmits), skips sensor discovery and the scan, and ELM327.raw refuses every command that isn't an adapter command (AT/ST; ATSI, ATFI, ATBI, ATRTR and STPX are refused too). request() always throws `ELMError.listenOnly` on such a connection.
- **OBD on UDS (SAE J1979-2)**: if 0100 gets no answer at connect, the app tries 22 F400 on CAN 11-bit then 29-bit; if Mode 01 discovery finds nothing on a CAN car, it retries as 22 F4xx. With `obdOnUDS` on, `request("01xx")` is sent as 22 F4xx and replies 62 F4 xx… are rewritten as 41 xx… (layouts identical per CSS DBC v4.3); `0902` is sent as 22 F802 and rewritten as 49 02 01 + VIN. Multi-PID requests are off in this mode. Trouble codes on these cars come from All Modules (UDS 19 02 FF). Not yet tested on a real J1979-2 car.
- **O2 sensors**: 14–1B now also give short-term trim (100/128·B − 100 %, B = FF → not used); 24–2B give sensor voltage (8/65536·CD V); 34–3B give sensor current (CD/256 − 128 mA). Shown under the dashboard tile and in reports. Sources: Wikipedia "OBD-II PIDs", CSS Electronics OBD2 DBC v4.3.
- DTC.parse ignores frames that aren't 4x replies (a 7F negative response is no longer read as codes).
