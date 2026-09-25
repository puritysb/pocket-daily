# Screenshot set

Every file is actual Pocket Daily 1.0 demo-mode UI, produced by
`scripts/capture_screenshots.sh` and flattened to an opaque PNG at an accepted
size. Regenerated on 2026-09-25 for the Home & Sleep studio.

| Destination | Directory | Dimensions | Files |
|---|---|---:|---|
| iPhone 6.9-inch | `en-US/iphone-6.9` | 1320 × 2868 | `01-home-x3`, `02-sleep-x3`, `03-cards`, `04-reader` |
| iPad 13-inch | `en-US/ipad-13` | 2064 × 2752 | `01-home-x3`, `02-sleep-x3`, `03-cards`, `04-home-x4` |
| Mac | `en-US/mac-16x10` | 2880 × 1800 | `01-home-x3`, `02-cards`, `03-home-x4` |

Every set opens on Home & Sleep. The iPhone keeps reader controls in a Reader
tab, so it earns a Reader shot; iPad already shows them beside the studio and
shows the X4 instead. The Mac set is rendered off-screen from one state per
shot, so it carries three. `validate_app_store.sh` enforces the counts and
that no two files in a device class are identical — a byte-identical pair is
how a layout-dependent capture step silently no-ops.

## How they are produced

- iPhone and iPad come from `PocketUITests`, driven in the simulator with a
  fixed 9:41 status bar.
- Mac comes from `PocketMacTests`, which hosts the shipping SwiftUI views in an
  off-screen window and asks that window to draw itself. It is deliberately a
  unit test: the macOS UI-test runner needs the Accessibility permission to
  enable automation mode, which cannot be granted from a script or CI.

Suggested App Store Connect captions:

1. **Arrange your reader's Home screen** (`01-home-x3`)
2. **Compose the Daily Brief it shows while asleep** (`02-sleep-x3`)
3. **Write study cards at e-paper resolution** (`03-cards`, `02-cards` on Mac)
4. **Connect, send files and adjust settings** (`04-reader`), or **X3 and X4
   layouts** (`04-home-x4`, `03-home-x4` on Mac)

If the UI changes materially, rerun `scripts/capture_screenshots.sh` and commit
the new set. Do not edit a new feature into an old screenshot.
