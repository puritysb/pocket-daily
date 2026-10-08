# Pocket Daily App Store package

This directory contains the App Store Connect copy, review notes, privacy and
age-rating answers, required-size screenshots, and export configuration for
Pocket Daily 1.0.

## Prepared values

- Universal app name: **Pocket Daily**
- Bundle ID: `bound.serendipity.pocket.daily`
- SKU: `pocket-daily-universal-2026`
- Version/build: `1.0.0 (1)`
- Platforms: iOS/iPadOS and macOS
- Categories: Education, then Books
- Price: Free; no purchases or account
- Privacy answer: **No, we do not collect data from this app**
- Privacy manifest: app-only UserDefaults (`CA92.1`) and user-selected file metadata (`3B52.1`)
- Encryption: no non-exempt encryption
- Release: manual after approval

Localized customer copy is under `metadata/en-US` and `metadata/ko-KR`; both
describe the same shipped interface. Screenshots under `screenshots/en-US` are
generated from the built-in local demo by `scripts/capture_screenshots.sh`
(see `screenshots/README.md`), flattened to opaque PNG files at Apple's accepted
dimensions: six for iPhone, seven for iPad and six for Mac. The same set may be
uploaded to both storefront localizations.

## Locally verified release evidence

- Organization team `QF36NDHYHD` can provision both products. The iOS Store
  profile includes Hotspot Configuration, and the Mac Store profile preserves
  the sandbox and required hardware/file/network capabilities.
- App Store exports succeeded for both platforms: an arm64 iOS IPA and a
  universal arm64/x86_64 macOS PKG, both signed with Apple Distribution.
- Both exported apps contain `PrivacyInfo.xcprivacy`; their distribution
  entitlements and signatures were verified from the packaged products.
- On 2026-09-06 the iOS simulator test suite passed 40 tests, the macOS build
  passed, the screenshot set was regenerated from the current UI, and
  `scripts/validate_app_store.sh` passed the staged submission package. The
  signed exports below predate those source changes; rerun
  `scripts/package_app_store.sh` before upload.
- The safe local packaging script completed end to end and emitted verified IPA,
  PKG, test-result, signature/profile, entitlement, and SHA-256 evidence.
- The configured marketing, support, and privacy URLs return HTTP 200 from the
  public GitHub Pages site.

The packaging script runs the deterministic unit tests only; the UI-test bundles
that capture screenshots and check first-run behaviour run from the full scheme
so a simulator problem cannot hang a release build.

Build, test, archive, locally export, and verify both products with:

```sh
./scripts/package_app_store.sh
```

The script never uploads. It isolates Xcode from a conflicting Homebrew rsync,
uses only `ExportOnlyOptions.plist`, verifies the packaged signatures, profiles,
architectures, entitlements, versions, and privacy manifests, and emits a
`release-evidence.json` with artifact sizes and SHA-256 hashes. Use
`--skip-tests` only for a packaging rerun after the same source revision has
already passed the complete suite.

## Account-holder steps

1. In App Store Connect, create one app record with the prepared name, bundle ID,
   and SKU. Add iOS and macOS platforms to the record.
2. Copy localized metadata and screenshots into App Store Connect.
3. Answer App Privacy with the value in `privacy_answers.json`, generate the
   archive Privacy Report and confirm it matches, complete the current age-rating
   questionnaire using `age_rating_answers.json`, and declare content rights.
4. Record the physical-reader clip in `review/REVIEW_VIDEO_CHECKLIST.md`; place its
   unlisted URL and `review/NOTES.md` text in Review Information.
5. Upload the prepared iOS and macOS distributions to the app record.
   `ExportOnlyOptions.plist` creates local IPA/PKG files; `ExportOptions.plist`
   is intentionally separate and configured for an explicit upload operation.
   Before uploading, refresh the App Store Connect account in Xcode or configure
   an authorized API key; the current local Xcode account has no upload token.
6. Test both builds in TestFlight with a real reader before manual submission,
   following `testflight/TEST_PLAN.md`, including firmware rejection and a valid
   firmware staging run without flashing.

Run `scripts/validate_app_store.sh` before archive. The validator intentionally
keeps the account, build-upload, TestFlight, and physical-review evidence in
`submission.json` as external release work rather than source repository defects.

## Article library development — 2026-09-28

Library → Articles supports saved links/text and local RSS 2.0 / Atom 1.0 subscriptions.
Choose + → Subscriptions and paste a direct HTTPS feed URL. The latest 20 entries per
feed are collected on subscription, app activation (at most once per five minutes), or
manual refresh. There is no email account integration or scheduled background delivery.
Feed-provided full text and extracted original pages are saved for offline reading.
Extraction failures keep a link and preview; Get full text allows retry or pasted text.
Subscriptions and page requests go directly to publishers without browser cookies,
credentials, scripts, images or an extraction service. Demo mode does not fetch feeds.

Tap an offline article to read in the app; its menu offers Save for later, read/unread,
Edit article, Send to Reader… and Delete. Reading and saving are independent.
Unsubscribing retains collected articles; refresh does not restore deleted feed articles.
Content, subscriptions and these flags stay on this device. Reader preparation and
sending remain explicit and use the existing EPUB format. The iOS/iPadOS Share →
Pocket Daily extension and + → Add article remain available for manual captures.

Library and My Reader are the two main destinations. My Reader combines device status, pending work and its inventory. Reader settings
contains Home, Sleep and Reading preferences; Reader options (•••) opens Manage reader. Sending selected content uses a task sheet
in the current window; its connection, send and result steps preserve the
selection. On Mac, SD card is a destination in that same task; only the output
folder is selected, and SD-copy results stay separate from wireless results.
It does not send unrelated prepared books or firmware. Home/Sleep settings open shared
card and weather/calendar source editors separately from Home/Sleep layout,
with one Apply action per active editor. Settings also
opens in the current window. Local checks of this IA revision are recorded in
[the implementation report](../docs/IA_IMPLEMENTATION_REPORT.md); prior signed exports are not evidence for the new UI.

The app and extension require the App Group `group.bound.serendipity.pocket.daily`.
The extension bundle ID is `bound.serendipity.pocket.daily.share`. Registering
these capabilities and obtaining matching distribution profiles are authorized
account-holder actions, still pending; unsigned local builds do not verify them.
The extension must ship with matching parent version/build and privacy manifest.
Article sending requires reader `articleLibrary: 1` plus the streaming transport.
See `docs/ARTICLES.md` (from repository root) for the contract and acceptance gates.
This is not a new Store submission or a verified physical sharing flow.
