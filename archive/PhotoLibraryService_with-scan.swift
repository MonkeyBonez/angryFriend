import Photos
import UIKit
import os

// Thread-safe once-only resolution token. Used by loadImage to race the PHImageManager
// callback against a timeout without waiting for PHImageManager to actually cancel.
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if resolved { return false }
        resolved = true
        return true
    }
}

// Mutable request-ID box, so the timeout task can read the ID the PHImageManager
// call produced (value is set synchronously before the timeout could possibly fire).
private final class RequestIDBox: @unchecked Sendable {
    var id: PHImageRequestID = PHInvalidImageRequestID
}

// Holds the timeout task so the image callback can cancel it on success —
// otherwise every loadImage call leaves a task sleeping the full 20s.
private final class TimeoutTaskBox: @unchecked Sendable {
    var task: Task<Void, Never>?
}

actor PhotoLibraryService {
    private static let logger = Logger(subsystem: "com.angryFriend", category: "PhotoLibrary")
    static let shared = PhotoLibraryService()

    func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    func fetchAssets(since date: Date) -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(
            format: "mediaType == %d AND creationDate > %@",
            PHAssetMediaType.image.rawValue, date as CVarArg
        )
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    func fetchAllCameraRollAssets() -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    /// Nonisolated so multiple callers can request images concurrently.
    /// Every call has an internal timeout — after `timeoutSeconds` we abandon the
    /// PHImageManager request and return nil. This prevents stuck iCloud assets from
    /// blocking extraction or the iCloud scan's workers indefinitely.
    nonisolated func loadImage(
        for asset: PHAsset,
        targetSize: CGSize = CGSize(width: 1024, height: 1024),
        allowNetwork: Bool = false,
        fastMode: Bool = false,
        timeoutSeconds: Double = 20
    ) async -> UIImage? {
        let box = ResultBox()
        let idBox = RequestIDBox()
        let timeoutBox = TimeoutTaskBox()
        let assetID = asset.localIdentifier

        return await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat  // single full-res callback, no degraded thumbnail
            options.resizeMode = fastMode ? .fast : .exact
            options.isNetworkAccessAllowed = allowNetwork
            options.isSynchronous = false

            // Kick off the PHImageManager request.
            idBox.id = PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                // If the timeout already won, discard this result.
                guard box.claim() else { return }

                // Cancel the pending timeout so it doesn't sleep the full duration.
                timeoutBox.task?.cancel()

                if image == nil {
                    let shortID = assetID.prefix(8)
                    let err = (info?[PHImageErrorKey] as? NSError)?.localizedDescription ?? "unknown"
                    let isCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false
                    PhotoLibraryService.logger.warning("loadImage nil for \(shortID): cloud=\(isCloud), err=\(err)")
                }
                cont.resume(returning: image)
            }

            // Start the timeout task. If it wins the race we cancel the PHImageManager
            // request (best-effort) and resume the continuation ourselves. On the normal
            // path the image callback cancels this task so it exits immediately.
            timeoutBox.task = Task.detached(priority: .userInitiated) {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                guard !Task.isCancelled, box.claim() else { return }
                PHImageManager.default().cancelImageRequest(idBox.id)
                PhotoLibraryService.logger.warning("loadImage TIMEOUT after \(timeoutSeconds)s for \(assetID.prefix(8)) (network=\(allowNetwork))")
                cont.resume(returning: nil)
            }
        }
    }
}
