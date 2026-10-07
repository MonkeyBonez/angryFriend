#if DEBUG
import Photos
import SwiftData
import os

/// Test hook: launched with `-seedTestFriend`, an empty app creates a friend from
/// the 10 newest photos in the library, then starts the background scan — so
/// the scan can be exercised in the Simulator (`xcrun simctl addmedia`) without
/// tapping through the picker.
enum ScanTestSeed {
    private static let logger = Logger(subsystem: "com.angryFriend", category: "TestSeed")

    @MainActor
    static func runIfRequested(context: ModelContext) async {
        guard ProcessInfo.processInfo.arguments.contains("-seedTestFriend") else { return }
        let status = await PhotoLibraryService.shared.requestAuthorization()
        logger.info("Seed: photo access status \(status.rawValue)")
        guard ((try? context.fetchCount(FetchDescriptor<Friend>())) ?? 0) == 0 else { return }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 10
        var assets: [PHAsset] = []
        PHAsset.fetchAssets(with: .image, options: options).enumerateObjects { asset, _, _ in assets.append(asset) }

        guard let service = try? FaceMatchingService() else { return }
        let discovery = await service.discoverFriendIdentity(in: assets)
        guard !discovery.identity.isEmpty else {
            logger.error("Seed: no recurring face in the 10 newest photos")
            return
        }
        let friend = Friend(name: "Seed", stickerData: Data(), photoMatches: discovery.matches.map {
            PhotoMatch(assetID: $0.asset.localIdentifier, faceBoundingBox: $0.faceBoundingBox)
        })
        friend.identity = discovery.identity
        context.insert(friend)
        try? context.save()
        logger.info("Seed: created a friend from \(discovery.matches.count) of \(assets.count) photos")
        FriendRescanner.shared.ensureRunning()
    }
}
#endif
