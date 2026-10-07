# Reader customization capabilities

Audited 2026-10-05 against the sibling `pocket-daily-firmware` checkout, read-only.
This table describes Pocket Daily / compatible firmware; it does not claim
factory firmware compatibility. The model selector while offline is an example.
Hardware behavior and panel parity remain physical acceptance checks.

## Settings and scopes

`GET /api/pocket/v1/preferences` is the capability source for optional settings.
Missing or invalid optional fields are hidden and omitted from POST, including
orientation, line spacing, margins, side layout, front rotation and WAKE.
The four original required fields must decode successfully before preferences
are applied. Do not infer support solely from a version string or X3/X4 model.

| Scope / field | Valid values | Effect and support |
| --- | --- | --- |
| Home / `startupApp` | 0 Home, 1 Pocket Daily | Next startup destination. Original required preferences field. |
| Home / profile `home.items` | GET-advertised known items, ordered, 1–4 | Reading, app cards, daily word when advertised. Retired daemon items are removed locally. |
| Home / profile `home.dailyWord` | Boolean | Fallback word when no app card. |
| Home / profile `home.weather` | `top`, `bottom`, `off` | Shared Daily panel placement. |
| Home / profile `home.nextEvent` | Boolean | Next event line in Daily panel; invisible while panel is off. |
| Sleep / profile `sleep.mode` | `brief`, `reader` | Daily Brief or the sleep screen chosen on the reader. Custom sleep images are not fetched. |
| Sleep / profile `sleep.sections` | GET-advertised known sections, ordered, unique, at least one | Reading, first card, card/word, weather, today as advertised. |
| Sleep / `pocketDailySleepCover` | Boolean / wire 0,1 | Book cover in Daily Brief. Original required field. |
| Sleep / `sleepTimeoutMinutes` | Integer 1–31 | 31 never sleeps automatically. Original required field. |
| Sleep / `sleepWakeIndicator` | Boolean / wire 0,1 | Optional GET field. Next sleep frame shows WAKE at physical power switch, including covers/custom/Quick Resume. Does not change power behavior. |
| Reading / `fontSize` | Integer 0–3 | Original API uses 12/14/16/18-point buckets. Firmware stores precise point sizes internally; posting the unchanged bucket preserves a precise reader-selected size. Font family/point-size selection remains on the reader. |
| Reading / `orientation` | 0 portrait, 1 landscape clockwise, 2 portrait inverted, 3 landscape counter-clockwise | Optional GET field. Next book render; rotates the page, not vertical writing. |
| Reading / `lineSpacing` | 0 tight, 1 normal, 2 wide, 3 extra wide | Optional GET field; next book render. |
| Reading / `screenMargin` | Integer 5–40 px | Optional GET field. API accepts all integers in range; app slider offers 5 px steps matching reader UI. |
| Reading / `sideButtonLayout` | 0 previous/next, 1 next/previous, 2 no page turn | Optional GET field. API accepts these three layouts; firmware has additional device-local layouts which this API does not expose. Takes effect on button queries. |
| Reading / `frontButtonFollowOrientation` | Boolean / wire 0,1 | Optional GET field. Rotation policy flips navigation and page key actions in inverted / counter-clockwise orientations. Screen directional controls rotate according to firmware's orientation table. |
| Shared content | Cards, chosen weather city, all/selected calendars | One source for Home and Sleep. Explicit content Apply; never sweeps Reading drafts. Nil calendar IDs means all, [] means none; missing selected IDs do not fall back to all. |

Profile support additionally requires `/api/status` `pocketProfile:1`, confirmed
identity and the generation returned by profile GET. The app scopes each edit
onto the last reader baseline because profile POST carries the whole document.
Home Apply cannot send Sleep/Reading drafts. All preferences are loaded before
applying their scoped baseline. A profile change uses generation compare-and-swap.

## Physical keys and rotation

The labels refer to the chassis held upright, with its front facing the user.
X3 has page keys on the left and right edges and two front rocker controls.
X4 has upper/lower page keys on its right edge and four separate front keys.
Firmware logical Up/Down map to those first/second physical page keys. The
rotated diagram preserves physical key locations while updating page actions.

| Model | First page key | Second page key | Power / WAKE |
| --- | --- | --- | --- |
| X3 | Left edge (logical Up) | Right edge (logical Down) | Top switch |
| X4 | Upper right-edge key (logical Up) | Lower right-edge key (logical Down) | Upper-right switch |

| Orientation | Follow rotation off | Follow rotation on |
| --- | --- | --- |
| Portrait | Keep chosen side layout | Keep chosen side layout |
| Landscape clockwise | Keep chosen side layout | Keep chosen side layout; screen-direction controls rotate |
| Portrait inverted | Keep chosen side layout | Swap the chosen previous/next actions |
| Landscape counter-clockwise | Keep chosen side layout | Swap the chosen previous/next actions; screen-direction controls rotate |

Side layout Off means neither key turns pages for every orientation. Swapped
layout reverses the table again. Front Back/Confirm/Left/Right may be remapped
on-device; the preferences endpoint does not expose that custom map, so the
companion does not claim specific per-front-key actions. Power bypasses remaps.
WAKE stays anchored to the physical switch in portrait regardless of reading
orientation. Home/Settings use portrait; reading orientation does not rotate them.

## Preview, saved and shown

Home and Daily Brief use the existing pinned host renderer with sample book,
weather and schedule plus local cards. Reading is an illustrative SwiftUI sample,
not the EPUB device renderer. A successful preferences save does not open a book.
A saved layout is shown only when a presentation receipt confirms `home`/`brief`;
otherwise report saved and describe when it will render. Reading is not a
presentation surface. Live frame, saved capture and UI-pack APIs were removed
2026-10-01; no preview uses them.

## Evidence

- Sibling `docs/nearby-sync-v1.md`, preferences section.
- Sibling `docs/pocket-profile-v1.md`, capability sets and generation contract.
- Sibling `src/pocket_daily/web/PreferencesUpdate.cpp` and `PocketEndpoints.cpp`:
  accepted ranges, all-body validation, bucket preservation and rollback.
- Sibling `src/MappedInputManager.cpp`: physical page keys, rotation table,
  page/navigation swaps and device-local front remaps.
- Sibling `src/pocket_daily/home/HomeDrawing.cpp` physical geometry: X3 page
  keys at y=194 on the 792px portrait panel and front centers 91/207/321/437;
  X4 page keys at y=385/465 on the 800px panel and front centers 78/183/298/403.
- Sibling `src/util/PowerWakeCue.h`: physical X3 top switch x=473 and X4
  upper-right switch y=74; portrait anchoring independent of page orientation.
- Sibling `lib/hal/HalGPIO.h`: X3 edge keys / X4 vertical rocker distinction.
- Sibling `src/CrossPointSettings.h` and `src/SettingsList.h`: local settings,
  margins/timeout and extended local side layouts.
- Sibling `docs/live-studio-v1.md`: remaining status/preference pushes and
  removed live-screen APIs; host preview is not a device screenshot.
