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
    var identityData: Data? = nil           // up to 10 face embeddings, flat [Float] bytes — the template a rescan matches against is their mean
    var negativeData: Data? = nil           // faces the user said aren't this friend ("Not them"), same encoding as identityData
    var notThemChecked: Int = 0             // how many "Not them" faces the album was last re-checked against; -1 → re-check
    var identityVersion: Int = 0            // which matching rules built `identityData` and checked the album; below `currentIdentityVersion` → rebuilt and re-checked once
    var catchUpBefore: Date? = nil          // own walk back through photos the shared walk passed before this friend joined
    var catchUpFloor: Date? = nil           // ...down to here, where the shared walk was; nil → not joined the scan yet
    var excludedIDs: [String] = [String]()  // removed from the album on purpose — a rescan must never add them back
    var pendingPickedIDs: [String] = [String]()  // picked photos discovery stopped before reaching; the scan checks them first
    var sortOrder: Int = 0                  // place in the home line-up; lower first, ties newest first

    init(name: String, stickerData: Data, photoMatches: [PhotoMatch]) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.stickerData = stickerData
        self.photoMatches = photoMatches
        self.identityVersion = Self.currentIdentityVersion
    }

    /// Bumped whenever the matching rules or the face model change: stored
    /// faces are rebuilt and albums re-checked once. 1 = mean template,
    /// one-person-per-face assignment, 5-point alignment; 2 = ResNet50 model
    /// (embeddings from different models can't be compared). Both 2026-10-07.
    static let currentIdentityVersion = 2
}

extension Friend {
    /// Still has photos the shared walk passed before they joined.
    var needsCatchUp: Bool {
        guard let catchUpBefore, let catchUpFloor else { return false }
        return catchUpBefore > catchUpFloor
    }

    /// Matching template: the mean of the stored faces, plus the "Not them"
    /// faces. Nil until there are faces.
    var template: FaceTemplate? { FaceTemplate(faces: identity, negatives: negatives) }

    /// Picked photos still waiting for the scan (discovery committed early).
    var hasPendingPicks: Bool { !pendingPickedIDs.isEmpty }

    /// New "Not them" faces since the album was last re-checked against them.
    var needsNotThemRecheck: Bool { notThemChecked != negatives.count }

    /// Most "Not them" faces kept per friend; the oldest go first.
    static let negativeLimit = 50

    /// Faces the user said aren't this friend. Embeddings from one face model:
    /// cleared when the model changes (see `currentIdentityVersion`).
    var negatives: [FaceEmbedding] {
        get { Self.decodeFaces(negativeData) }
        set { negativeData = Self.encodeFaces(Array(newValue.suffix(Self.negativeLimit))) }
    }

    /// The friend's stored faces (`identityData`). Empty for friends saved
    /// before rescanning existed — the rescanner derives and stores it once.
    var identity: [FaceEmbedding] {
        get { Self.decodeFaces(identityData) }
        set { identityData = Self.encodeFaces(newValue) }
    }

    private static func decodeFaces(_ data: Data?) -> [FaceEmbedding] {
        guard let data else { return [] }
        let dim = FaceEmbedding.dimension
        var floats = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
        _ = floats.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        guard !floats.isEmpty, floats.count % dim == 0 else { return [] }
        return stride(from: 0, to: floats.count, by: dim).map {
            FaceEmbedding(vector: Array(floats[$0..<$0 + dim]))
        }
    }

    private static func encodeFaces(_ faces: [FaceEmbedding]) -> Data? {
        let floats = faces.filter { $0.vector.count == FaceEmbedding.dimension }.flatMap(\.vector)
        return floats.isEmpty ? nil : floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
