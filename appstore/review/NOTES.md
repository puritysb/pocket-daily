# App Review notes

Pocket Daily is an account-free, distraction-free e-book reader for iPhone, iPad and Mac, and the companion for separately obtained X3/X4-class e-paper hardware running Pocket Daily or compatible CrossPoint-based firmware. Reading needs no hardware. It does not support a manufacturer's factory firmware or cloud service. No login, purchase, subscription, or remote service is required.

## Review without hardware

1. Launch Pocket Daily. It opens on the **Library**, which holds a short original guide, "Welcome to Pocket Daily". Tap it to read: tap the right or left side of the page to turn, the middle for Contents, Aa (text and page) and the way back to the Library. On Mac the book opens in the same window.
2. Add DRM-free EPUB, TXT or Markdown files with **+**, or save an article from Safari's share sheet and read it under **Articles**. **+ → Subscriptions** accepts a direct HTTPS RSS or Atom feed URL; feeds are fetched directly from the publisher when subscribing, when the app becomes active (at most once every five minutes) and on manual refresh. Demo mode never fetches feeds.
3. **Settings → Continue Reading** shows iCloud key-value storage between the user's own Apple devices and exchange with a connected reader over the local connection. No Pocket Daily account is needed. Settings opens from the sidebar, the Library header on iPhone, or ⌘, on Mac, in the current app window.

**Background Bluetooth (`bluetooth-central`, iOS/iPadOS):** the app uses this background mode only to keep reading places in step with the one reader the user paired with **Connect directly**. It keeps a single pending connection to that bonded reader (no scanning, no other accessories, no pairing in the background). When the reader closes a book, wakes or goes to sleep, it may advertise if memory allows. Background delivery is OS controlled; when connected, the app exchanges reading places over the encrypted link (book fingerprint, position, percentage and device name; no file names or book contents), then disconnects. No page moves until the user accepts an offered place. Turning off **Continue Reading → Your X3/X4 reader** cancels it, and demo mode never connects. Observing it requires a physical reader.
4. For the companion without a reader, open **My Reader → Device** and choose **Try demo**. My Reader also has **On Reader**, **Screens**, and **Reading** destinations. Screens shows Home and Sleep previews drawn locally with sample content; nothing is captured from a reader. Switch Home/Sleep above the preview and adjust the layout. My cards is available from Screens. Reading uses an illustrative book with model-specific page-button actions. Weather and calendar controls are optional: outside demo, a named city uses Apple Weather and calendars can be selected with permission. Source edits stay local until explicitly applied; event contents are not stored by the app or sent anywhere except the user's reader.
5. Reader settings are populated in demo mode. Apply, applying settings and sending files are intentionally disabled because no physical reader is connected. Choose **Exit demo** under Device to return to normal discovery.

The submitted screenshot build can also be launched with `--demo` by the development team; reviewers do not need launch arguments because the same mode is visible in the interface.

## Live hardware flow

1. Choose **Send to Reader…** for a Library book or saved article. The task sheet
   keeps the selected content while connecting and never includes unrelated
   prepared books or firmware. Firmware has its own validated update flow.
2. For shared Wi-Fi, open File Transfer → Join a Network on the reader and
   choose Find on same Wi-Fi. This requests local-network access without BLE or
   automatic Wi-Fi switching.
3. Away, open Nearby Sync on the reader (new firmware has a transport chooser),
   expand the other connection methods, choose Connect directly in the app,
   and confirm the Wi-Fi transition. BLE
   pairing supplies the temporary credentials. No router or internet is required.
4. Choose Send in the task sheet and keep the iPhone app open. Close and reopen
   that task to see the same progress; closing is not cancellation. Direct sessions defer
   preview/crash requests to preserve reader memory. Pending files survive an
   interruption; resume depends on firmware capability and retained session state.
   On Mac, the same selected-book task offers an SD card destination; choose
   only its output folder and explicitly copy. The source book stays selected,
   and SD results do not overwrite wireless results. Demo blocks folder access
   and copying.
5. Successful direct batches release the temporary connection. New firmware also
   exits the private session. Firmware still requires reader-side confirmation;
   reconnect to verify the version for an identified reader.
6. Firmware in **My Reader → Device** checks official release availability
   outside demo mode. On a connected reader, the acknowledged **Update** action
   downloads, validates and sends the image to that connection. **Download update
   for later** prepares it locally instead; the user later connects and confirms
   **Send update**. The reader asks separately before installing. A delivered
   image is not reported as installed until the identified reader reconnects
   with the expected version. Firmware runs only on the reader; nothing
   downloaded executes in the app.

The app does not read location coordinates. On supported Apple OS versions, location permission may be requested only because the system gates Wi-Fi hotspot configuration behind that permission. The bundled privacy manifest declares app-only UserDefaults and user-selected file-metadata access; the app does not track or collect data.

## Reviewer attachment still required

Before submission, attach a short, unedited video showing one physical reader completing discovery, transfer, and reader-side confirmation. Follow [REVIEW_VIDEO_CHECKLIST.md](REVIEW_VIDEO_CHECKLIST.md). Replace the placeholder video URL in App Store Connect review notes.
