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
and saved reader Wi-Fi remain prerequisites. An initially offline reader cannot
be recovered by this preflight; consult the firmware guide instead of retrying
unknown mutations or switching the Mac network.

Quick app build, actual connection, fresh file inventory and a generated EPUB round trip:

```sh
python3 ../pocket-daily-firmware/scripts/dev_pipeline.py run --app "$PWD"
```

Exercise BLE wake twice against already installed experimental X3 standby firmware:

```sh
python3 ../pocket-daily-firmware/scripts/dev_pipeline.py run \
  --app "$PWD" --standby --cycles 2
```

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
  or file for diagnosis; inspect the report before cleanup.
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
