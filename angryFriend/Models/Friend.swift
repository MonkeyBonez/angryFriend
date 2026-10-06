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
    var photoMatches: [PhotoMatch] = [PhotoMatch]()  // every photo this friend was found in — picked or found by rescan
    var identityData: Data? = nil           // up to 3 face embeddings, flat [Float] bytes — what a rescan matches against
    var lastScannedAt: Date? = nil          // camera roll is checked for photos newer than this; nil → createdAt
    var pendingCloudIDs: [String] = [String]()  // new photos with no local copy yet — the iCloud pass picks these up
    var backfillBefore: Date? = nil         // older photos are checked back from here; nil → createdAt
    var backfillDone: Bool = false          // the whole library before createdAt has been checked
    var excludedIDs: [String] = [String]()  // removed from the album on purpose — a rescan must never add them back

    init(name: String, stickerData: Data, photoMatches: [PhotoMatch]) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.stickerData = stickerData
        self.photoMatches = photoMatches
    }
}

extension Friend {
    /// The friend's face, as stored in `identityData`. Empty for friends saved
    /// before rescanning existed — the rescanner derives and stores it once.
    var identity: [FaceEmbedding] {
        get {
            guard let identityData else { return [] }
            let dim = FaceEmbedding.dimension
            var floats = [Float](repeating: 0, count: identityData.count / MemoryLayout<Float>.size)
            _ = floats.withUnsafeMutableBytes { identityData.copyBytes(to: $0) }
            guard !floats.isEmpty, floats.count % dim == 0 else { return [] }
            return stride(from: 0, to: floats.count, by: dim).map {
                FaceEmbedding(vector: Array(floats[$0..<$0 + dim]))
            }
        }
        set {
            let floats = newValue.filter { $0.vector.count == FaceEmbedding.dimension }.flatMap(\.vector)
            identityData = floats.isEmpty ? nil : floats.withUnsafeBufferPointer { Data(buffer: $0) }
        }
    }
}
