# Reader resources and SD files

Implemented 2026-09-27; physical acceptance remains pending on updated firmware.

The Reader panel shows RAM free bytes and, when `totalHeap` is present, a used
percentage. RAM is working memory, not a file destination. SD files are separate
from firmware installation. Prepared content displays its exact SD destination;
preparing content does not send it. The Sync file browser lists folders and
reading files, with an explicit permanent-deletion confirmation. App originals
are retained. Hidden/system folders and firmware cannot be deleted here.

## Contract (app and sibling firmware)

Sync `/api/status` advertises `readerFiles: 1` and optional `totalHeap` bytes.
Older firmware remains supported: free RAM only, no invented SD usage.
All endpoints below require the current `deviceID` query and refuse work while
uploads/presentation are busy or the reader has insufficient working memory.
Identity matching prevents accidental cross-device operations; it is not LAN
authentication. Responses use `Cache-Control: no-store`.

- `GET /api/pocket/v1/files?deviceID=…&path=/&cursor=0`: returns `deviceID`,
  `path`, `entries` (name, directory, size bytes, deletable), `nextCursor`.
  At most 12 rows / 48 inspected entries per request. Cursor is a 32-byte aligned
  directory offset, bounded to 8 MiB; zero means finished. Hidden, dot, reserved
  system paths are excluded. This is a live listing, not a snapshot: refresh
  after changes. A folder may contain unsupported files shown as read only.
- `DELETE /api/pocket/v1/files?deviceID=…&path=…&size=…&cursor=0`: only EPUB,
  TXT, MD, XTC files. Size must still match or 409 is returned. Removes associated
  reading cache/recent-book state and article completion marker. Returns
  `deviceID` and `deleted: true`. The app also checks the identity from the
  original listing before submitting confirmation.
- `GET /api/pocket/v1/storage?deviceID=…&cursor=0`: returns `deviceID`,
  `totalBytes`, `freeBytes` for this chunk, `nextCursor`, `supported`.
  FAT16/FAT32 scan up to 4096 clusters per request, using a temporary 512-byte
  sector buffer with watchdog yields. The app sums chunks, validates fixed
  capacity and cursor progression, and supports cancellation between requests.
  Other formats expose capacity only (`supported: false`). Usage is a refreshed
  estimate; external changes during the scan require refreshing again.

No recursive delete, formatting, moving system files, or RAM editing is exposed.
File browsing and SD usage require firmware containing these endpoints; this
change has not yet been installed on the physical X3. Directory enumeration uses
SdFat's entry iterator: exceptionally sparse/damaged directories still require
hardware timing validation. Reboot/SD removal during a delete may leave cleanup
incomplete; refresh the folder to establish whether the file remains.
