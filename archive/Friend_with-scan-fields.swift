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
    var localScanCompleted: Bool = false        // true once local pass finishes fully
    var localLastScannedDate: Date? = nil      // creationDate of last LOCAL asset scanned (for resumption)
    var iCloudPassCompleted: Bool = false      // true once the iCloud background scan finishes fully
    var iCloudLastScannedDate: Date? = nil     // creationDate of last iCloud asset scanned (for resumption)

    init(name: String, stickerData: Data, seedImageData: [Data], matchedAssetIDs: [String]) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.lastScannedAt = Date()
        self.stickerData = stickerData
        self.seedImageData = seedImageData
        self.matchedAssetIDs = matchedAssetIDs
    }
}
