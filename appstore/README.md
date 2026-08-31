# Pocket Daily App Store package

This directory contains the App Store Connect copy, review notes, privacy answer,
required-size screenshots, and export configuration for Pocket Daily 1.0.

## Prepared values

- Universal app name: **Pocket Daily**
- Bundle ID: `io.github.puritysb.pocketdaily`
- SKU: `pocket-daily-universal-2026`
- Version/build: `1.0.0 (1)`
- Platforms: iOS/iPadOS and macOS
- Categories: Education, then Books
- Price: Free; no purchases or account
- Privacy answer: **No, we do not collect data from this app**
- Encryption: no non-exempt encryption
- Release: manual after approval

Localized customer copy is under `metadata/en-US` and `metadata/ko-KR`.
Screenshots under `screenshots/en-US` are actual app output in the built-in local
demo, flattened to opaque PNG files at Apple's accepted dimensions. The same
set may be uploaded to both storefront localizations; the reader surface already
demonstrates Korean and Japanese glyph rendering.

## Account-holder steps

1. In Certificates, Identifiers & Profiles, register the bundle ID and enable
   Hotspot Configuration for iOS. Confirm App Sandbox/Bluetooth/network/file
   access for macOS.
2. In App Store Connect, create one app record with the prepared name, bundle ID,
   and SKU. Add iOS and macOS platforms to the record.
3. Enable GitHub Pages for `main` → `/docs`, then confirm the marketing, support,
   and privacy URLs return HTTP 200.
4. Copy localized metadata and screenshots into App Store Connect.
5. Answer App Privacy with the value in `privacy_answers.json`, complete the 4+
   age-rating questionnaire truthfully, and declare content rights.
6. Record the physical-reader clip in `review/REVIEW_VIDEO_CHECKLIST.md`; place its
   unlisted URL and `review/NOTES.md` text in Review Information.
7. Select team `R22679GY5Z`, archive each platform, validate, and upload. The
   provided `ExportOptions.plist` is ready for automatic App Store signing.
8. Test both builds in TestFlight with a real reader before manual submission.

Run `scripts/validate_app_store.sh` before archive. The validator intentionally
reports the four account-only items in `submission.json`; those are not source
repository defects.
