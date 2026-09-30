# Screenshot set

Every file is actual Pocket Daily 1.0 demo-mode UI, produced by
`scripts/capture_screenshots.sh` and flattened to an opaque PNG at an accepted
size. All three sets were regenerated on 2026-09-30 after the appearance refresh
(brand accent, adaptive palette, capsule progress bars, paper covers).

| Destination | Directory | Dimensions | Files |
|---|---|---:|---|
| iPhone 6.9-inch | `en-US/iphone-6.9` | 1320 × 2868 | `01-reading`, `02-library`, `03-home-x3`, `04-cards`, `05-device`, `06-articles` |
| iPad 13-inch | `en-US/ipad-13` | 2064 × 2752 | `01-reading`, `02-library`, `03-home-x3`, `04-cards`, `05-home-x4`, `06-articles`, `07-device` |
| Mac | `en-US/mac-16x10` | 2880 × 1800 | `01-library`, `02-home-x3`, `03-card-x3`, `04-sleep-x4`, `05-articles`, `06-device` |

Reading and the Library lead the sets. Screens holds the Home/Sleep editor
and its persistent preview; Device holds connection, files and firmware.
Articles shows subscriptions populated from local publisher fixtures.
The iPhone set has six images, iPad seven, and Mac six. Mac is rendered
off-screen from the same shipping views. `validate_app_store.sh` enforces the counts and
that no two files in a device class are identical — a byte-identical pair is
how a layout-dependent capture step silently no-ops.

## How they are produced

- iPhone and iPad come from `PocketUITests`, driven in the simulator with a
  fixed 9:41 status bar.
- Mac comes from `PocketMacTests`, which hosts the shipping SwiftUI views in an
  off-screen window and asks that window to draw itself. The window is made key
  and the view is told it is active, otherwise AppKit draws every control in
  the dimmed background style. macOS switches (`Toggle`) still follow the real
  application activation, which a test runner cannot obtain, so they render
  grey in the Mac set even though the app draws them in the accent color.
- The iOS simulators are pinned to `en_US` before boot so the status-bar date
  matches the en-US metadata. It is deliberately a
  unit test: the macOS UI-test runner needs the Accessibility permission to
  enable automation mode, which cannot be granted from a script or CI.

Suggested App Store Connect captions:

1. **Read with room to focus** (`01-reading`)
2. **Your books, ready offline** (`02-library`, `01-library` on Mac)
3. **Arrange your reader’s screens** (`03-home-x3`, `02-home-x3` on Mac)
4. **Make cards of your own** (`04-cards`, `03-card-x3` on Mac)
5. **Keep your reading in one place** (`06-articles`, `05-articles` on Mac)
6. **Connect, copy and update** (`05-device`, `07-device` on iPad, `06-device` on Mac)

If the UI changes materially, rerun `scripts/capture_screenshots.sh` and commit
the new set. Do not edit a new feature into an old screenshot.
