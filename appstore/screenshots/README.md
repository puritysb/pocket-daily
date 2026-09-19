# Screenshot set

Every file is actual Pocket Daily 1.0 demo-mode UI, produced by
`scripts/capture_screenshots.sh` and flattened to an opaque PNG at an accepted
size. Regenerated on 2026-09-08.

| Destination | Directory | Dimensions | Files |
|---|---|---:|---|
| iPhone 6.9-inch | `en-US/iphone-6.9` | 1320 × 2868 | `01-profile-x3`, `02-inspector`, `03-about`, `04-profile-x4` |
| iPad 13-inch | `en-US/ipad-13` | 2064 × 2752 | `01-profile-x3`, `02-about`, `03-profile-x4` |
| Mac | `en-US/mac-16x10` | 2880 × 1800 | `01-profile-x3`, `02-about`, `03-profile-x4` |

The compact layout stacks the inspector below the reader preview, so it earns a
separate shot. The wide layouts already show the inspector beside the preview,
so they carry three. `validate_app_store.sh` enforces both the counts and that
no two files in a device class are identical — a byte-identical pair is how a
layout-dependent capture step silently no-ops.

## How they are produced

- iPhone and iPad come from `PocketUITests`, driven in the simulator with a
  fixed 9:41 status bar.
- Mac comes from `PocketMacTests`, which hosts the shipping SwiftUI views in an
  off-screen window and asks that window to draw itself. It is deliberately a
  unit test: the macOS UI-test runner needs the Accessibility permission to
  enable automation mode, which cannot be granted from a script or CI.

Suggested App Store Connect captions:

1. **See the reader profile you are connecting** (`01-profile-x3`)
2. **Send your own content and keep reader settings focused** (`02-inspector`,
   or `02-about` on the wide layouts)
3. **Independent and local-first by design** (`03-about` / `02-about`)
4. **X3 and X4 hardware profiles** (`04-profile-x4` / `03-profile-x4`)

If the UI changes materially, rerun `scripts/capture_screenshots.sh` and commit
the new set. Do not edit a new feature into an old screenshot.
