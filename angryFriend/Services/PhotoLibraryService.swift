import Photos
import UIKit
import os

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

    // Nonisolated so multiple tasks can call PHImageManager concurrently.
    nonisolated func loadImage(
        for asset: PHAsset,
        targetSize: CGSize = CGSize(width: 1024, height: 1024),
        allowNetwork: Bool = false,
        fastMode: Bool = false
    ) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat  // single full-res callback, no degraded thumbnail
            options.resizeMode = fastMode ? .fast : .exact
            options.isNetworkAccessAllowed = allowNetwork
            options.isSynchronous = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                if image == nil {
                    let id = asset.localIdentifier.prefix(8)
                    let err = (info?[PHImageErrorKey] as? NSError)?.localizedDescription ?? "unknown"
                    let isCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false
                    PhotoLibraryService.logger.warning("loadImage nil for \(id): cloud=\(isCloud), err=\(err)")
                }
                continuation.resume(returning: image)
            }
        }
    }
}
