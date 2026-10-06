import UIKit
import Photos
import SwiftData

/// A friend's cover sticker is a cutout, and it has to stay see-through: the
/// carousel and detail screen show the pastel tile through it, the same way a
/// game card does. JPEG has no alpha and flattens that background to black, which
/// is what the first covers were saved as — hence the repair pass below.
enum CoverSticker {
    /// Longest side kept in storage. The sticker is shown at 138pt at most.
    private static let storedSide: CGFloat = 600

    /// PNG, scaled down for storage, transparency intact.
    static func encode(_ cutout: UIImage) -> Data? {
        let longest = max(cutout.size.width, cutout.size.height)
        guard longest > storedSide else { return cutout.pngData() }
        let scale = storedSide / longest
        let size = CGSize(width: cutout.size.width * scale, height: cutout.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            cutout.draw(in: CGRect(origin: .zero, size: size))
        }
        return small.pngData()
    }

    /// True for stickers saved as JPEG, before covers kept their transparency.
    static func isFlattened(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0xFF && data[data.startIndex + 1] == 0xD8
    }

    /// Loads a photo and cuts the friend out of it — the one path shared by game
    /// setup, cover picking and the repair pass. Tries the local copy first.
    static func cutout(asset: PHAsset, box: CGRect) async -> UIImage? {
        let targetSize = CGSize(width: 1024, height: 1024)
        var image = await PhotoLibraryService.shared.loadImage(for: asset, targetSize: targetSize, allowNetwork: false)
        if image == nil {
            image = await PhotoLibraryService.shared.loadImage(for: asset, targetSize: targetSize, allowNetwork: true)
        }
        guard let image else { return nil }
        return await SubjectExtractionService.shared.extractSubject(from: image, faceBoundingBox: box)
    }

    private static var repaired = false
    /// Bump when the way cutouts are framed changes, so saved covers get re-cut
    /// to match the cards. 3 = subject fills 65% of the frame.
    private static let framingVersion = 3
    private static let framingVersionKey = "coverFramingVersion"

    /// Re-cuts covers that are out of date — still stored as JPEG, or framed by
    /// an older rule — once per launch, quietly behind the home screen. Each
    /// friend updates in place as their new sticker lands.
    static func repairFlattenedCovers(_ friends: [Friend], context: ModelContext) async {
        guard !repaired else { return }
        repaired = true
        let reframe = UserDefaults.standard.integer(forKey: framingVersionKey) < framingVersion
        defer { UserDefaults.standard.set(framingVersion, forKey: framingVersionKey) }

        for friend in friends where reframe || isFlattened(friend.stickerData) {
            let candidates = Array(friend.photoMatches.prefix(10))
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: candidates.map(\.assetID), options: nil)
            var assetsByID: [String: PHAsset] = [:]
            fetched.enumerateObjects { asset, _, _ in assetsByID[asset.localIdentifier] = asset }

            for match in candidates {
                guard let asset = assetsByID[match.assetID],
                      let cutout = await cutout(asset: asset, box: match.faceBoundingBox),
                      FaceMatchingService.hasDetectableFace(in: cutout),
                      let data = encode(cutout) else { continue }
                friend.stickerData = data
                try? context.save()
                break
            }
        }
    }
}
