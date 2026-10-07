import Foundation
import SwiftData

/// Where the background scan is in the photo library: one row, shared by every
/// friend. The library is walked by shot date, newest to oldest, so "which
/// photos has the scan seen" is a pair of dates, not a list of IDs.
///
/// - Forward: photos added or changed since `newestModifiedSeen`, oldest change
///   first, checked against every friend — new shots, AirDrops, saved images.
/// - Backward: the shared walk, `walkBefore` down to the oldest photo, also
///   checked against every friend. Each friend's own `catchUpBefore` /
///   `catchUpFloor` covers what the walk had already passed when they joined.
@Model
final class ScanState {
    var newestModifiedSeen: Date = Date()   // forward cursor; only ever moves later
    var walkStartedAt: Date = Date()        // the walk began here (photos newer than this are the forward pass's)
    var walkBefore: Date? = nil             // photos shot before this are still to walk; nil → walkStartedAt
    var walkDone: Bool = false              // the walk reached the oldest photo
    var pendingCloudIDs: [String] = [String]()  // need a full-size iCloud download before they can be ruled out
    var cloudRetriesData: Data = Data()     // [assetID: failed downloads], JSON

    init() {
        let now = Date()
        newestModifiedSeen = now
        walkStartedAt = now
    }

    /// The single row, created on first use.
    static func load(in context: ModelContext) -> ScanState {
        if let existing = try? context.fetch(FetchDescriptor<ScanState>()).first {
            return existing
        }
        let state = ScanState()
        context.insert(state)
        try? context.save()
        return state
    }

    /// Where the walk is: photos shot before this have not been walked yet.
    var walkCursor: Date { walkBefore ?? walkStartedAt }

    var cloudRetries: [String: Int] {
        get { (try? JSONDecoder().decode([String: Int].self, from: cloudRetriesData)) ?? [:] }
        set { cloudRetriesData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
}
