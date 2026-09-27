# Articles: save on the phone, read and tidy on the reader

2026-09-27. Working-tree feature, not a submitted release. Physical acceptance is pending.

## User journey

1. While browsing on iPhone/iPad, Share → Pocket Daily opens an article capture sheet.
   On Mac, or without sharing, Files → Add → Articles → Add article accepts a link or text.
2. Sharing an HTTPS link starts a bounded page request. Review/edit the extracted title and
   body, then Save. No reader or local-network connection is needed. A failed extraction
   can be saved as a **link only**, or supplied with selected/pasted text. Link-only items
   cannot be prepared for the reader.
3. Articles keeps the local title, source and full text across app restarts. Review opens
   the full saved text. Prepare for reader creates a durable EPUB copy in Files. Connect
   and explicitly Send. No reconnection, library refresh or reader deletion triggers a send.
4. Reader Home → Articles shows the newest articles with title, source host and New /
   Reading / Read state. Open uses the existing EPUB reader and resume cache. Back returns
   to Articles; the end-of-book screen records Read. Articles are exempt from the ordinary
   finished-book auto-move setting and remain in this collection.
5. Hold Open on an article to confirm deleting that reader copy. The final list action
   confirms deletion of the displayed collection's read articles and shows their count.
   App copies remain. Delete in the app likewise does not remotely delete a reader copy.
6. Explicitly preparing/sending the same stored item uses the same UUID filename, replacing
   its reader copy. Normal commit cache invalidation resets progress; its read marker is
   also removed. An edited, resent item is a fresh reader copy, not an incremental edit.

The first version is text-only and one EPUB per article. No bundles, image fetching, feed
subscriptions, paywall/login bypass, cloud extraction or automatic background delivery.
Opening a link does not use browser session cookies. UTF-8 HTML up to 4 MiB is parsed
in memory with system libxml2; scripts/resources are not executed/fetched. Article/main
containers are preferred; generic pages can contain unrelated text, hence mandatory review.
The extension saves through the same local store, not through a network relay.

## App/firmware contract v1

- `/api/status` advertises `articleLibrary: 1`. Sending requires this capability and the
  existing streaming upload. Legacy readers keep their prepared copy and show an update hint.
- Publication uses the existing verified staging/commit protocol, no new endpoint:
  `/Articles/pd-article-<lowercase UUID>.epub`. UUID has canonical 8-4-4-4-12 spelling.
  Streaming transport creates the parent if absent. Ordinary book transfer is unchanged.
- EPUB layout remains EPUB 3 + NCX with STORE ZIP. First local entry is `mimetype`,
  exact 20-byte `application/epub+zip`, no extra field or flags. The second local entry
  is `META-INF/pocket-article.bin`, uncompressed, without flags/extra fields, exactly 523 bytes.
  ZIP CRC32 covers the metadata; reader checks its header, size, CRC and UTF-8 fields.
- Metadata bytes: 0–3 ASCII `PDA1`; 4–11 unsigned little-endian saved Unix seconds
  (0 <= value < 253402300800); 12–268 title, UTF-8 NUL terminated and zero padded
  (max 256 bytes); 269–522 source host or `Saved text`, same encoding/padding (max 253 bytes).
  Title/host must be nonempty and cannot contain ASCII control bytes. Full HTTPS source URL
  appears as a link in the EPUB body, not in the list metadata. Metadata is inside the EPUB
  so transfer cannot publish a list entry without its book or require sidecar coordination.
- The list opens only this bounded metadata; it does not parse EPUB bodies or generate caches.
  It indexes the newest 128 valid articles (additional older files remain on SD), and keeps
  at most eight visible metadata rows. The limit is explicitly shown; deleting entries
  exposes older ones. Invalid metadata is excluded; Files remains available for damaged files.
- Reading uses existing EPUB progress files. A completed article has a one-byte `1` marker
  at `/.crosspoint/articles/<UUID>.done`; empty/invalid markers do not mean Read. Writes are
  attempted on the transition to End of Book, not on every loop or page. Save failure logs
  a failure and never deletes content. Reader deletion removes EPUB, cache, recents entry,
  and marker. Replacement removes the marker; no app-side reconciliation resurrects deletion.
- Reader list state is allocated only for this activity and released before reading/network
  activity. The compile-time bound is under 13 KiB; physical heap/orientation results remain
  unmeasured. Existing GUI callbacks use strings for visible row text; no body-sized allocation.

## Signing and verification gates

The iOS app/extension share App Group `group.bound.serendipity.pocket.daily`; extension ID
is `bound.serendipity.pocket.daily.share`. App-group provisioning is required for physical
installation/distribution. No account-holder capability registration or Store upload was done.
macOS stores articles in its sandboxed Application Support; it has no new sharing extension
or app-group requirement. Articles are not synchronized between Apple devices.

Simulator UI tests need ad-hoc signing (`CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`) so
app-group entitlements are present. The screenshot script uses that for iOS. Disabling code
signing remains sufficient for compile checks, but cannot test shared-container access.

Required physical acceptance: Safari URL and selected-text sharing; link-only save followed
by extraction; connect/send/open/title/source/Unicode; close/reopen at the same page; end
and Read state; delete confirmation cancel/success; restart persistence; SD failure;
reconnect does not resend; explicit resend replaces; X3/X4 and four orientations; heap.
Use existing Same Wi-Fi transfer for hardware iteration. Do not infer these from builds.

## Local verification — 2026-09-27

- App: 319 unit tests passed before the final networking/summary-store additions;
  final focused run passed all 7 ArticleTests and both article UI tests. The latter
  exercises the real system share extension, local persistence across relaunch,
  EPUB preparation and confirmed app deletion. Final iOS/extension and macOS builds pass.
- Firmware: final 439 host tests and 11 route tests pass; strict cppcheck reports no
  defects and the default firmware build reports no errors or warnings.
- All 11 App Store screenshots regenerated, representative images inspected on each
  platform, and package validation passed. Existing app HostRendererBridge unused-result
  build warning remains. Screenshot validation does not verify reader Articles rendering.
- No physical installation, device acceptance, account capability registration, commit,
  push or submission was performed. Hardware gates above remain open.

Transfer category separation, interruption cleanup and reader feedback are specified in
[TRANSFERS.md](TRANSFERS.md).
