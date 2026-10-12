# Reader development from the app repository

Use this workflow when changing discovery, Bluetooth wake, connection ownership,
reader inventory, transfer protocols or behavior that needs a firmware change.
The runner and its authoritative operating instructions belong to the sibling
firmware repository:
[App–reader developer pipeline](../../pocket-daily-firmware/docs/developer-pipeline.md).
Keep firmware build/deployment tooling there; add shared app scenarios here.

## Start from this checkout

The commands below run from the `pocket-daily` repository root. `--app "$PWD"`
selects this exact checkout, including local app changes. If the repositories
are not siblings (for example an app worktree), resolve the firmware checkout
explicitly and retain `--app "$PWD"`.

First inspect the existing ignored firmware `build/dev-pipeline.json`; if the
same reader is already enrolled, reuse it. Otherwise, with the development
reader in Same Wi-Fi, enroll it once (replace the address placeholder):

```sh
python3 ../pocket-daily-firmware/scripts/dev_pipeline.py configure --host <reader-ip>
```

Close any separately running Pocket Daily instance before the run; the test host
must own the radio and reader HTTP traffic. The runner rejects duplicate apps
before reader I/O. During an agent-led iteration, handle this setup without
asking the user to repeat reader menus. Initial OS permissions, Bluetooth pairing
and saved reader Wi-Fi remain prerequisites. A stale saved address automatically falls back to the Debug app's normal
Connect flow (Bonjour/current-LAN discovery and bonded BLE wake). Only the enrolled
reader identity is admitted. The runner independently rechecks identity, Same
Wi-Fi mode and development version over HTTP before atomically saving its new
address and continuing the requested scenarios. No new IP input or re-enrollment
is needed after DHCP/Wi-Fi changes. Initial enrollment is still required.

The reader must already know the new Wi-Fi (or be provisioned through the app's
Wi-Fi setup). This does not copy credentials, switch the Mac network, recover a
powered-off/deep-sleep reader or bypass network isolation. Discovery is bounded;
a failed or stale result leaves the runner's enrollment unchanged. The app and
runner both start with the saved address hint, so a fresher app cache cannot hide
a broken discovery path in this test. Reports distinguish `saved-address` from
`app-discovery` and include a separate discovery `.xcresult`.

Quick app build, actual connection, fresh file inventory and a generated EPUB round trip:

```sh
python3 ../pocket-daily-firmware/scripts/dev_pipeline.py run --app "$PWD"
```

Exercise BLE wake twice against already installed experimental X3 standby firmware:

```sh
python3 ../pocket-daily-firmware/scripts/dev_pipeline.py run \
  --app "$PWD" --standby --cycles 2
```

For a bounded 30-minute idle/wake regression against matching development
firmware, add `--standby-seconds 1800`. The harness temporarily suspends model
LAN monitoring and reserves BLE ownership, so ordinary minute-by-minute reading
exchanges cannot keep the connection active. It restores both in a `defer`,
without changing saved sync preferences, before using the app's normal Connect
path. The result requires unchanged BLE exchange history during the wait, matching
firmware recovery deadline and measured standby duration. See the firmware guide
for the 90..1800-second range and wait-plus-90-second recovery boundary.

For a user-coordinated physical cable-removal/battery-only trial, add
`--standby --standby-seconds 300 --cycles 2 --battery-only`. Wait for
`POCKET_STANDBY_READY <run> waitSeconds=300` in the first hardware log before
asking the user to unplug the reader. The marker follows a single standby
request and an unsuccessful LAN probe; the eventual firmware evidence must still
prove actual standby and BLE wake. Keep the cable removed through both cycles.
The first covers removal during the trial; the second starts without the cable.
Record the user's physical confirmation separately in the private run directory.

`--battery-only` requires a noncharging firmware checkpoint above 10% in addition
to the ordinary idle/wake/transfer checks. Charging, missing power evidence or
battery protection cannot count as a pass. A noncharging sample alone does not
prove physical cable removal or continuous current measurement. No charging
threshold is lowered, and the test does not establish overnight battery life.

### Reproduce delayed BLE connection without physical intervention

With matching development firmware, `--standby --delayed-advertising --cycles 2`
withholds the reader's actual BLE advertiser until the requested standby wait
plus 16 seconds. Battery checks, buttons and the existing wait-plus-90-second
recovery remain active. The one-shot fault is absent from production builds and
does not persist into ordinary sleep. Installation still requires explicit
developer authorization and `--flash`.

The real app must record, in order: connecting, pending connection reset requested,
cancellation confirmed, scan started, enrolled advertisement observed, reconnect
requested, connected, authenticated, one command sent and matching acceptance.
The scan must start after at least 7.5 seconds and acceptance remain within the
original 20-second BLE deadline. Firmware reports requested and actual advertising
start times; missing/stale evidence, time-up return or ordinary fast connection
cannot pass this recovery scenario. Normal standby trials also record wake
milestones so a future natural failure retains its failed stage.

Add `--wake-control` only for the negative control: the test scheduler suppresses
the eight-second rediscovery action and preserves the real transport and original
deadline. It never fakes callbacks or command acceptance. A control connection
may succeed and must not be counted as proof of rediscovery recovery. Neither
an injected delay nor its successful recovery establishes the RF cause of a
historical failure without matching evidence. Current findings are in
[CURRENT_HANDOFF.md](CURRENT_HANDOFF.md).

When the user's developer iteration includes firmware installation:

```sh
python3 ../pocket-daily-firmware/scripts/dev_pipeline.py run \
  --app "$PWD" --build-firmware ble_standby --flash --standby --cycles 2
```

This runs firmware gates, builds the Debug app, freezes the image, installs and
verifies the exact version after reboot, then repeats actual app Connect and
inventory operations. For ordinary firmware use `--build-firmware default`
without `--standby`. Standby is experimental X3 light sleep, not BLE wake from
deep sleep. Production firmware and the shipping app update flow are separate.

Add `--ios-simulator <udid>` for shared protocol regression tests, or
`--ios-device <udid>` for the physical iPhone scenario after the Mac scenario.
Discover available simulators with `xcrun simctl list devices available`.
Physical iPhone testing needs an unlocked, provisioned, permissioned and paired
Debug app. Simulator success does not establish physical radio behavior.

## Extend and diagnose

For the full unattended app regression and 10-case physical interface suite, see
[READER_INTERFACE_VALIDATION.md](READER_INTERFACE_VALIDATION.md). The focused
runner option is `--interface-suite`; it requires every case and cleanup to pass.
Add `--screen-suite` for 14 actual X3 Home/Brief/card/EPUB/sleep/wake captures, local
image/OCR checks, timer deep sleep and automatic Same Wi-Fi return. This requires
the matching development firmware; it never flashes implicitly. Wake evidence
requires a matching run, an unchanged body, a changed cue and a measured
1..1500 ms refresh. Physical button timing and optical quality remain separate.

- [HardwareTests/ReaderHardwareTests.swift](../HardwareTests/ReaderHardwareTests.swift)
  is shared by `PocketTests` and `PocketMacTests`. It uses the running app's
  actual model, clients and connection ownership. Add bounded scenarios here
  for app behavior; keep deterministic parsing/state tests under `Tests/`.
- [ReaderDevelopmentContext](../Sources/ReaderDevelopmentContext.swift) holds a
  weak Debug-only model reference. Keep it out of Release; do not add a product
  control server or a second Bluetooth/model instance for the harness.
- The hardware scenario also prepares and sends a uniquely named generated EPUB through
  the running app, downloads it to compare all bytes, then deletes only that exact
  generated path and size and checks the refreshed inventory. It uses a temporary
  library, never an existing user book. A failed run may leave its generated task
  or file for diagnosis; inspect the report before cleanup. On `transferState` v1
  firmware it also checks automatic return to idle and a fresh app heartbeat;
  older firmware is explicitly reported as unsupported for that check.
- Normal unit tests skip hardware without I/O. The runner explicitly opts in;
  enabled simulator hardware tests fail. Skipped or stale evidence is not a pass.
- Reports and `.xcresult` bundles are in the firmware checkout's ignored
  `build/dev-pipeline-runs/<run>/`. Read `report.json` and the failed stage log,
  fix the owning repository, then rerun the same scenario. A lost flash or sleep
  request is observed rather than blindly repeated. Reports/logs stay local.
- These scenarios supplement the app's ordinary affected tests and UI checks;
  they do not establish every transfer/content flow, iPhone background behavior,
  X4 compatibility, battery life or release readiness. Record exactly which
  image, app checkout and scenarios passed in the handoff.

For the verified baseline see [PROJECT_MEMORY.md](PROJECT_MEMORY.md); physical
acceptance boundaries remain in [CONNECTIVITY_VALIDATION.md](CONNECTIVITY_VALIDATION.md).

`--wifi-setup` adds an explicitly opted-in production BLE Wi-Fi provisioning
failure/recovery scenario. It sends a unique nonexistent SSID, checks the
matching failure receipt and old-network return, and does not read or log real
credentials. See [READER_WIFI_SETUP.md](READER_WIFI_SETUP.md) for positive-test
requirements and the protocol boundary.

## Transfer network-loss acceptance

`--interface-suite --network-faults` opts into two one-shot faults in compatible
X3 developer firmware. It runs the shipping app model, first losing real reader
Wi-Fi association after at least 64 KiB of an owned upload, then losing the commit
reply after publication and its receipt have reached SD. The reader waits five
seconds before reconnecting to its saved network. No Mac Wi-Fi change or router
administration is involved; this is not proof of router reboot/DHCP reassignment.

The suite requires run-bound firmware evidence of actual offline observation,
network return, a resumed prefix for the first case and exactly one publication
for each. If the job needs foreground recovery, the harness invokes the normal
Connect/retry actions on the same persisted job. Both recovered files must match
the original byte for byte; original inventory and settings must be preserved.
A missing fault, early reconnect, restart from zero, repeated publication or
unconfirmed job fails the test. Use the firmware runner's separately authorized
`--build-firmware ble_standby --flash` only to install the required developer build.

Download evidence now records admission/queue, request, busy backoff, saving,
verification and terminal phases, byte/request counts, elapsed/progress age and
error code. Each request must complete once even when rejected or cancelled
before I/O. Counters contain no filename, contents, network address or identity.
The test report retains failed-stage evidence as well as successful downloads.

### Bidirectional reading acceptance

`--continuity-suite` runs on the physical Mac and X3, using the matching developer
firmware. It uploads an isolated, run-named EPUB, opens the shipping Mac reader,
and exercises forward and backward app offers. X3 accepts through its rendered
reading confirmation dialog, closes the actual EPUB activity to record its page,
and returns to Same Wi-Fi. A subsequent real X3 page turn is offered back to the
Mac; the harness locates the shipping Go-to button in its rendered banner with local
OCR and dispatches mouse events to that test window. A Mac UI test guards this
route (off-screen SwiftUI hosting views do not expose AX children).
Receiving an offer must not move either reader before acceptance.

Each round requires matching text after the XPointer in the saved X3 framebuffer (offline
Vision OCR), a unique subsequent checkpoint, and the exact target character in
the Mac's visible page range, plus a changed X3 exit sequence.
BMP/PNG attachments are exported and hash-checked by the firmware runner. The
original reader progress list, recent-book order and file inventory must be
restored; failures preserve recovery artifact paths. No simulator, router change
or manual page turn is involved. This checks HTTP position exchange and actual
acceptance; it does not establish iCloud or BLE-only continuation, optical panel
quality, or layout parity for every EPUB.

```sh
python3 ../pocket-daily-firmware/scripts/dev_pipeline.py run --app "$PWD" \
  --build-firmware ble_standby --flash --continuity-suite
```

Omit build/flash when the matching developer firmware is already installed.

`--continuity-suite --real-epub` substitutes the sibling's public-domain
Standard Ebooks Frankenstein fixture (226309 bytes, 38 spine sections) for the
small generated checkpoint book. Its original spine XHTML is retained; images
are 1×1 placeholders, so this is not image-rich EPUB acceptance. The test imports
its unchanged bytes, sends them through the app, downloads/reimports into a
separate library, then checks forward/backward offers using source-character
anchors and the actual visible Mac range. A preexisting matching reader-history
digest is refused. The developer capture admission is now 1 byte..4 MiB on SD;
this does not allocate a file-sized buffer or change shipping reader limits.
The runner requires the fixture SHA-256 and both byte-preservation results.

For short comprehensive acceptance without an extended standby trial:

```sh
python3 scripts/verify_reader_interface.py --physical-only --screen-suite --continuity-suite --real-epub --network-faults
```

The screen suite still enters real timer deep sleep briefly and returns on its
own. Its retained body must exactly match the selected Brief preview (header
and footer are excluded because wake hints and power state change there).

For an element-boundary XPointer (for example a chapter's `/body`), acceptance
checks the first following non-whitespace source character in the visible page.
It does not mistake the preceding DOM boundary for an invisible character.
Text-node offsets still require that exact point; other chapters, off-page
paragraphs and inexact paths fail. The Mac chapter-boundary regression covers
these positive and negative cases without hardware.

## Rehearse first app installation (Mac Debug only)

With explicit authorization to reset local settings, stop every companion
instance and launch the signed Debug app binary once with
`--developer-fresh-start`. Before constructing the fleet, this archives the
app's `Application Support/Pocket` and the main/current reader preference domains
under `Application Support/PocketFirstInstallBackups/<UUID>` in its own sandbox.
Only then are those preference domains cleared. Backup failure stops launch;
book bytes remain recoverable. The app then starts its ordinary welcome/library
flow without demo mode or remembered readers. Subsequent launches omit the flag.
The command is compiled out of Release and iOS. It does not erase iCloud,
other applications, OS Bluetooth records or permission decisions.

For a reader-side fresh start, use the firmware guide's explicitly acknowledged
`dev/fresh-start` operation. Reconnecting or pairing after the reset consumes the
initial-setup state; leave both sides unpaired for the person rehearsing it.
