import Photos
import UIKit
import os

/// Races a PHImageManager request against its deadlines. The request settles
/// exactly once — the image callback or the watchdog, whichever claims first.
private nonisolated final class LoadWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved = false
    private var lastProgress = Date()
    let started = Date()
    var requestID: PHImageRequestID = PHInvalidImageRequestID

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if resolved { return false }
        resolved = true
        return true
    }

    var isResolved: Bool {
        lock.lock(); defer { lock.unlock() }
        return resolved
    }

    /// The download moved — push the idle deadline back.
    func touch() {
        lock.lock(); defer { lock.unlock() }
        lastProgress = Date()
    }

    var idleFor: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(lastProgress)
    }
}

/// How hard to try for a photo.
nonisolated enum LoadPolicy: Sendable {
    /// Full size, this device only. Reports `.inCloud` when the original isn't here.
    case localFull
    /// Whatever rendition is already on the device, however small — for photos
    /// whose original is in iCloud. No download.
    case localFast
    /// Full size, downloading from iCloud if needed. Gives up after `idle`
    /// seconds without progress, or `max` seconds in all.
    case download(idle: TimeInterval, max: TimeInterval)
}

nonisolated enum LoadOutcome {
    case loaded(UIImage)
    case inCloud    // only in iCloud, and the policy didn't allow a download
    case failed     // timed out, cancelled, or unreadable
}

/// One step of a walk through the library: the photos to check, and where the
/// next step starts. `next == nil` means the walk has reached the end.
nonisolated struct LibraryStep {
    let assets: [PHAsset]
    let next: Date?
}

actor PhotoLibraryService {
    private static let logger = Logger(subsystem: "com.angryFriend", category: "PhotoLibrary")
    static let shared = PhotoLibraryService()

    func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    nonisolated func authorizationStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    // MARK: - What the rescan looks at

    /// Photos worth running face matching on. Out: anything under 300px a side
    /// (icons, thumbnails, stickers) by predicate; screenshots, panoramas and
    /// animated images in `isScannable`. Videos are out by media type; hidden
    /// photos and the extra frames of a burst by `PHFetchOptions` defaults.
    private nonisolated static let scanFilter = NSPredicate(format: "pixelWidth >= 300 AND pixelHeight >= 300")

    /// Subtypes can't go in the predicate: PhotoKit gets `(mediaSubtypes & x) == 0`
    /// wrong — on a test library it matched 1 photo of 178, the one with a bit set.
    private nonisolated static let skippedSubtypes: PHAssetMediaSubtype = [.photoScreenshot, .photoPanorama]

    private nonisolated static func isScannable(_ asset: PHAsset) -> Bool {
        asset.playbackStyle != .imageAnimated   // GIFs
            && asset.mediaSubtypes.isDisjoint(with: skippedSubtypes)
    }

    private nonisolated func fetch(_ predicate: NSPredicate, sortKey: String, ascending: Bool, limit: Int = 0) -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: sortKey, ascending: ascending)]
        options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [predicate, Self.scanFilter])
        options.fetchLimit = limit
        return PHAsset.fetchAssets(with: .image, options: options)
    }

    /// Photos within a millisecond of each other count as a tie: a step always
    /// takes the whole tie group at its edge, then steps this far past it.
    private nonisolated static let tieWindow: TimeInterval = 0.001

    /// Back through the library by shot date: up to `limit` photos shot before
    /// `cursor` (and not before `floor`), newest first, plus every photo sharing
    /// the oldest one's timestamp — so a "Save all" of 300 photos stamped with
    /// the same second is taken in one go instead of looping or being skipped.
    /// The next cursor is strictly earlier than this one.
    nonisolated func stepBack(before cursor: Date, floor: Date? = nil, limit: Int) -> LibraryStep {
        var bounds = [NSPredicate(format: "creationDate < %@", cursor as NSDate)]
        if let floor { bounds.append(NSPredicate(format: "creationDate >= %@", floor as NSDate)) }
        let page = fetch(NSCompoundPredicate(andPredicateWithSubpredicates: bounds),
                         sortKey: "creationDate", ascending: false, limit: limit)
        guard let edge = page.lastObject?.creationDate else { return LibraryStep(assets: [], next: nil) }

        var ties = [NSPredicate(format: "creationDate >= %@ AND creationDate <= %@",
                                edge.addingTimeInterval(-Self.tieWindow) as NSDate, edge as NSDate)]
        if let floor { ties.append(NSPredicate(format: "creationDate >= %@", floor as NSDate)) }
        let tie = fetch(NSCompoundPredicate(andPredicateWithSubpredicates: ties), sortKey: "creationDate", ascending: false)
        return LibraryStep(assets: Self.merge(page, tie), next: edge.addingTimeInterval(-Self.tieWindow))
    }

    /// Forward through the library by when photos last changed: up to `limit`
    /// photos added or edited after `cursor`, oldest change first, plus the tie
    /// group at the newest one. Catches new shots and photos saved with an old
    /// shot date (AirDrop, imports, saved attachments) alike.
    nonisolated func stepForward(after cursor: Date, limit: Int) -> LibraryStep {
        // A photo stamped in the future (a camera with its clock wrong) waits
        // until its time comes, rather than dragging the cursor past real photos.
        let page = fetch(NSPredicate(format: "modificationDate > %@ AND modificationDate <= %@", cursor as NSDate, Date() as NSDate),
                         sortKey: "modificationDate", ascending: true, limit: limit)
        guard let edge = page.lastObject?.modificationDate else { return LibraryStep(assets: [], next: nil) }
        let tie = fetch(NSPredicate(format: "modificationDate >= %@ AND modificationDate <= %@",
                                    edge as NSDate, edge.addingTimeInterval(Self.tieWindow) as NSDate),
                        sortKey: "modificationDate", ascending: true)
        return LibraryStep(assets: Self.merge(page, tie), next: edge.addingTimeInterval(Self.tieWindow))
    }

    /// The page and its tie group, deduped, animated images dropped.
    private nonisolated static func merge(_ page: PHFetchResult<PHAsset>, _ tie: PHFetchResult<PHAsset>) -> [PHAsset] {
        var seen = Set<String>()
        var assets: [PHAsset] = []
        for result in [page, tie] {
            result.enumerateObjects { asset, _, _ in
                if seen.insert(asset.localIdentifier).inserted, isScannable(asset) { assets.append(asset) }
            }
        }
        return assets
    }

    /// Photos shot before `cursor` (and not before `floor`) — what a walk has left.
    nonisolated func count(before cursor: Date, floor: Date? = nil) -> Int {
        var bounds = [NSPredicate(format: "creationDate < %@", cursor as NSDate)]
        if let floor { bounds.append(NSPredicate(format: "creationDate >= %@", floor as NSDate)) }
        return fetch(NSCompoundPredicate(andPredicateWithSubpredicates: bounds), sortKey: "creationDate", ascending: false).count
    }

    /// Photos added or edited after `cursor` — what the forward pass has left.
    nonisolated func count(changedAfter cursor: Date) -> Int {
        fetch(NSPredicate(format: "modificationDate > %@ AND modificationDate <= %@", cursor as NSDate, Date() as NSDate),
              sortKey: "modificationDate", ascending: true).count
    }

    /// Loads one photo under `policy`. Nonisolated so callers can load several
    /// at once.
    nonisolated func load(
        _ asset: PHAsset,
        targetSize: CGSize = CGSize(width: 1024, height: 1024),
        policy: LoadPolicy
    ) async -> LoadOutcome {
        let watch = LoadWatch()
        let assetID = asset.localIdentifier
        let shortID = String(assetID.prefix(8))

        let options = PHImageRequestOptions()
        options.isSynchronous = false
        let idle: TimeInterval
        let limit: TimeInterval
        switch policy {
        case .localFull:
            options.deliveryMode = .highQualityFormat   // one full-size callback, no degraded thumbnail
            options.resizeMode = .exact
            options.isNetworkAccessAllowed = false
            (idle, limit) = (20, 20)
        case .localFast:
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false
            (idle, limit) = (10, 10)
        case .download(let idleTimeout, let maxTimeout):
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .exact
            options.isNetworkAccessAllowed = true
            // Fires as the download moves; a slow but steady download keeps going.
            options.progressHandler = { _, _, _, _ in watch.touch() }
            (idle, limit) = (idleTimeout, maxTimeout)
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<LoadOutcome, Never>) in
            watch.requestID = PHImageManager.default().requestImage(
                for: asset, targetSize: targetSize, contentMode: .aspectFit, options: options
            ) { image, info in
                guard watch.claim() else { return }
                if let image {
                    cont.resume(returning: .loaded(image))
                } else if (info?[PHImageResultIsInCloudKey] as? Bool) == true, !options.isNetworkAccessAllowed {
                    cont.resume(returning: .inCloud)
                } else {
                    let err = (info?[PHImageErrorKey] as? NSError)?.localizedDescription ?? "unknown"
                    PhotoLibraryService.logger.warning("load nil for \(shortID): err=\(err)")
                    cont.resume(returning: .failed)
                }
            }

            // Watchdog: gives up on a request that stalls, or runs too long in all.
            Task.detached(priority: .utility) {
                while !watch.isResolved {
                    try? await Task.sleep(for: .milliseconds(500))
                    let stalled = watch.idleFor > idle
                    let tooLong = Date().timeIntervalSince(watch.started) > limit
                    guard stalled || tooLong else { continue }
                    guard watch.claim() else { return }
                    PHImageManager.default().cancelImageRequest(watch.requestID)
                    PhotoLibraryService.logger.warning("load gave up on \(shortID) after \(Int(Date().timeIntervalSince(watch.started)))s (\(stalled ? "stalled" : "too long"), network=\(options.isNetworkAccessAllowed))")
                    cont.resume(returning: .failed)
                    return
                }
            }
        }
    }

    /// Full-size image, or nil. With `allowNetwork` it downloads from iCloud,
    /// giving up after `timeoutSeconds` — used where someone is waiting on the
    /// result (cutouts, identity discovery, the album grid).
    nonisolated func loadImage(
        for asset: PHAsset,
        targetSize: CGSize = CGSize(width: 1024, height: 1024),
        allowNetwork: Bool = false,
        timeoutSeconds: Double = 20
    ) async -> UIImage? {
        let policy: LoadPolicy = allowNetwork ? .download(idle: timeoutSeconds, max: timeoutSeconds) : .localFull
        if case .loaded(let image) = await load(asset, targetSize: targetSize, policy: policy) {
            return image
        }
        return nil
    }
}
