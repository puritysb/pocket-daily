# App Store Connect submission checklist

Work through this in order. Everything in **Prepared** is already in the
repository; everything in **Account-holder actions** needs authorized access to
App Store Connect and cannot be completed or verified from this checkout.

Re-run `scripts/validate_app_store.sh` before you start, and
`scripts/package_app_store.sh` on the exact revision you intend to upload.

## Prepared in this repository

| Field | Value | Source |
|---|---|---|
| App name | Pocket Daily | `metadata/*/name.txt` |
| Subtitle | see file (en-US and ko-KR differ) | `metadata/*/subtitle.txt` |
| Bundle ID | `bound.serendipity.pocket.daily` | `project.yml` |
| SKU | `pocket-daily-universal-2026` | `submission.json` |
| Version / build | `1.0.0 (1)` | `project.yml` |
| Platforms | iOS, iPadOS, macOS (one record) | `submission.json` |
| Primary / secondary category | Education / Books | `submission.json` |
| Price | Free, no in-app purchases | `submission.json` |
| Age rating | 4+ | `age_rating_answers.json` |
| App Privacy | "No, we do not collect data from this app" | `privacy_answers.json` |
| Encryption | No non-exempt encryption | `submission.json` |
| Release | Manual after approval | `submission.json` |
| Marketing / support / privacy URLs | GitHub Pages, all HTTP 200 | `metadata/*/‌*_url.txt` |
| Description, keywords, promo text, release notes | en-US and ko-KR | `metadata/` |
| Screenshots | iPhone 6.9" ×4, iPad 13" ×3, Mac ×3 | `screenshots/` |
| Review notes | `review/NOTES.md` | |
| Review sample content | `review/Pocket-Daily-Review-Sample.epub` | |

## Account-holder actions

1. **App record.** Create one record with the name, bundle ID, and SKU above,
   then add both the iOS and macOS platforms to it.
2. **Metadata and screenshots.** Paste the localized copy and upload each
   screenshot directory to its matching display size. Captions are suggested in
   `screenshots/README.md`.
3. **Questionnaires.** Answer App Privacy, complete the current age-rating
   questionnaire, and declare content rights using the prepared JSON answers.
   Generate the archive's Privacy Report and confirm it matches.
4. **Review information.** Add the review contact name, phone, and email, paste
   `review/NOTES.md`, and attach the unlisted physical-reader video recorded
   per `review/REVIEW_VIDEO_CHECKLIST.md`.
5. **Upload builds.** Refresh the App Store Connect account in Xcode or
   configure an authorized API key first; the local Xcode account has no upload
   token. `ExportOnlyOptions.plist` produces the local IPA and PKG;
   `ExportOptions.plist` is the separate, explicit upload configuration.
6. **TestFlight with hardware.** Run `testflight/TEST_PLAN.md` on a physical
   iPhone or iPad and a Mac against a real reader, including the firmware
   rejection and staging boundaries.
7. **Submit and release.** Submit for review, then release manually.

## Known blockers

- The physical-reader review video does not exist yet. App Review will ask how
  the hardware features work, and the app cannot demonstrate a transfer without
  a reader.
- TestFlight verification against real hardware has not been run for this
  revision.
- The local Xcode account has no App Store Connect upload token.

## What a local run does and does not prove

`scripts/package_app_store.sh` builds, tests, archives, locally exports, and
verifies both signed products, then writes `release-evidence.json` with sizes
and SHA-256 hashes. It never uploads. A successful local export is not evidence
that App Store Connect accepted a build, that TestFlight passed, or that the app
was submitted or approved.
