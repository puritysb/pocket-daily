# App Review notes

Pocket Daily is an account-free, distraction-free e-book reader for iPhone, iPad and Mac, and the companion for separately obtained X3/X4-class e-paper hardware running Pocket Daily or compatible CrossPoint-based firmware. Reading needs no hardware. It does not support a manufacturer's factory firmware or cloud service. No login, purchase, subscription, or remote service is required.

## Review without hardware

1. Launch Pocket Daily. It opens on the **Library**, which holds a short original guide, "Welcome to Pocket Daily". Tap it to read: tap the right or left side of the page to turn, the middle for Contents, Aa (text and page) and the way back to the Library. On Mac the book opens in the same window.
2. Add DRM-free EPUB, TXT or Markdown files with **+**, or save an article from Safari's share sheet and read it under **Articles**. **+ → Subscriptions** accepts a direct HTTPS RSS or Atom feed URL; feeds are fetched directly from the publisher when subscribing, when the app becomes active (at most once every five minutes) and on manual refresh. Demo mode never fetches feeds.
3. Library options (the ellipsis menu) → **Continue Reading** shows iCloud key-value storage between the user's own Apple devices and exchange with a connected reader over the local connection; neither needs an account or setup.
4. For the companion without a reader, open **Device** (a tab in compact windows, a sidebar item on iPad and Mac) and choose **Try demo**. **Screens** then shows the reader's Home and Sleep screens drawn by the reader's own layout code with a sample card and built-in sample content, captioned as sample content; nothing in them is read from a device. Switch between Home and Sleep above the preview, turn Home pages or sleep sections on and off and drag them into order. **My cards** (opened from its Home page) holds a sample card; its image menu makes a QR code on the device. Under **Weather**, typing a city fetches Apple Weather for that city (no location permission); under **Calendar**, turning on events asks for Calendar access outside demo and reads only today's events, which are sent to a connected reader and nowhere else.
5. Reader settings are populated in demo mode. Apply, applying settings and sending files are intentionally disabled because no physical reader is connected. Choose **Exit demo** under Device to return to normal discovery.

The submitted screenshot build can also be launched with `--demo` by the development team; reviewers do not need launch arguments because the same mode is visible in the interface.

## Live hardware flow

1. Prepare a file with Add → Choose a file… under Files before switching networks. Firmware requires
   acknowledgement and is validated before entering the offline queue.
2. For shared Wi-Fi, open File Transfer → Join a Network on the reader and
   choose Find on same Wi-Fi. This requests local-network access without BLE or
   automatic Wi-Fi switching.
3. Away, open Nearby Sync on the reader (new firmware has a transport chooser),
   choose Connect directly in the app, and confirm the Wi-Fi transition. BLE
   pairing supplies the temporary credentials. No router or internet is required.
4. Choose Send under Ready to send and keep the iPhone app open. Direct sessions defer
   preview/crash requests to preserve reader memory. Pending files survive an
   interruption; resume depends on firmware capability and retained session state.
5. Successful direct batches release the temporary connection. New firmware also
   exits the private session. Firmware still requires reader-side confirmation;
   reconnect to verify the version for an identified reader.
6. Update reader (Device, only while a real reader is connected on the
   same Wi-Fi; hidden in demo mode) downloads the latest official firmware from
   the developer's public GitHub releases only when tapped, validates it, shows
   the firmware warning and sends it. The reader asks before installing. The
   firmware runs only on the reader; nothing downloaded executes in the app.

The app does not read location coordinates. On supported Apple OS versions, location permission may be requested only because the system gates Wi-Fi hotspot configuration behind that permission. The bundled privacy manifest declares app-only UserDefaults and user-selected file-metadata access; the app does not track or collect data.

## Reviewer attachment still required

Before submission, attach a short, unedited video showing one physical reader completing discovery, transfer, and reader-side confirmation. Follow [REVIEW_VIDEO_CHECKLIST.md](REVIEW_VIDEO_CHECKLIST.md). Replace the placeholder video URL in App Store Connect review notes.
