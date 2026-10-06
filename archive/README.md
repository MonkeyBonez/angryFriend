# Archive — scan-based pipeline (removed 2026-08-12)

These files are snapshots of the app before the "pick photos yourself" rebuild.
They're **not** part of the Xcode target (this folder lives outside
`angryFriend/`, so the `PBXFileSystemSynchronizedRootGroup` doesn't pick it up).

What was removed and why: the app used to offer a single-seed-photo flow that
scanned the entire camera roll (+ iCloud, in a resumable background pass) for
face matches. We replaced it with a manual multi-photo picker + on-device
identity discovery across the picked set, so this whole pipeline is no longer
part of the app. Kept here in case any of it — the two-stage
thumbnail-reject-then-embed scan, the iCloud resumption bookkeeping, the debug
threshold-tuning screen — is useful again later.

- `ScanningView_scan-based.swift` — full seed→scan→extract pipeline UI
- `DebugScanView.swift` — threshold-tuning tool built on `scanCameraRoll`
- `FacePickerView.swift` — multi-face disambiguation UI for a single seed photo
- `FaceMatchingService_with-scan.swift` — full service incl. `scanCameraRoll`,
  two-stage detection, single-image seed extraction
- `PhotoLibraryService_with-scan.swift` — incl. `fetchAllCameraRollAssets` /
  `fetchAssets(since:)`
- `ContentView_with-background-scan.swift` — incl. the iCloud background scan
  task for saved friends and its toast UI
- `SeedPickerView_with-scan.swift` — incl. the single "Choose Photo" flow
- `Friend_with-scan-fields.swift` — model incl. scan-resumption date/flag fields

**Update 2026-10-05:** an incremental rescan is back in the app
(`Services/FriendRescanner.swift`). It only checks photos taken since a friend's
last scan and matches them against that friend's stored identity. The
full-library scan in this folder is still not used.
