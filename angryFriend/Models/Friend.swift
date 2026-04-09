import SwiftData
import Foundation

@Model
final class Friend {
    var id: UUID = UUID()
    var name: String = ""
    var createdAt: Date = Date()
    var lastScannedAt: Date = Date()
    var stickerData: Data = Data()          // JPEG of extracted sticker from seed
    var seedImageData: [Data] = [Data]()    // JPEG of seed images (may be face crops)
    var matchedAssetIDs: [String] = [String]() // PHAsset.localIdentifier of all known matches
    var useZoomMode: Bool = false

    init(name: String, stickerData: Data, seedImageData: [Data], matchedAssetIDs: [String], useZoomMode: Bool) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.lastScannedAt = Date()
        self.stickerData = stickerData
        self.seedImageData = seedImageData
        self.matchedAssetIDs = matchedAssetIDs
        self.useZoomMode = useZoomMode
    }
}
