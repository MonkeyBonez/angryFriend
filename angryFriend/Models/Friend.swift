import SwiftData
import Foundation
import CoreGraphics

/// A single photo known to contain this friend, plus the face location Vision
/// found for them — persisted so future rounds can extract a cutout without
/// re-running identity discovery.
struct PhotoMatch: Codable, Hashable {
    var assetID: String
    var boxX: Double
    var boxY: Double
    var boxW: Double
    var boxH: Double

    var faceBoundingBox: CGRect {
        CGRect(x: boxX, y: boxY, width: boxW, height: boxH)
    }

    init(assetID: String, faceBoundingBox: CGRect) {
        self.assetID = assetID
        self.boxX = faceBoundingBox.origin.x
        self.boxY = faceBoundingBox.origin.y
        self.boxW = faceBoundingBox.width
        self.boxH = faceBoundingBox.height
    }
}

@Model
final class Friend {
    var id: UUID = UUID()
    var name: String = ""
    var createdAt: Date = Date()
    var stickerData: Data = Data()          // JPEG cover cutout — just this person, no one else
    var photoMatches: [PhotoMatch] = [PhotoMatch]()  // every picked photo this friend was found in

    init(name: String, stickerData: Data, photoMatches: [PhotoMatch]) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.stickerData = stickerData
        self.photoMatches = photoMatches
    }
}
