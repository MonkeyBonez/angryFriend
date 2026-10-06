import Foundation
import Photos
import SwiftData
import os

/// Looks through the camera roll for new photos of a saved friend whenever that
/// friend is picked to play, and grows their album with what it finds.
///
/// Two passes: photos already on the device first (fast, no downloads), then the
/// ones that only exist in iCloud. Lives on `AppState` rather than in a view so a
/// scan keeps going across the processing screen, the game and the result.
@Observable
@MainActor
final class FriendRescanner {
    enum Phase: Equatable {
        case idle
        case local
        case cloud
        case done
    }

    /// UserDefaults key behind the home screen's "auto-add new pics" switch.
    static let enabledKey = "autoScanNewPhotos"

    private static let logger = Logger(subsystem: "com.angryFriend", category: "Rescan")
    private static let cloudChunkSize = 12

    private(set) var phase: Phase = .idle
    private(set) var friendID: UUID? = nil

    private var task: Task<Void, Never>? = nil
    // Bumped on every start/cancel so a superseded scan can't touch state.
    private var generation = 0
    private var activeFriend: Friend? = nil
    private var activeContext: ModelContext? = nil

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    func isScanning(for friend: Friend) -> Bool {
        friendID == friend.id && (phase == .local || phase == .cloud)
    }

    /// Starts a scan for `friend`, replacing any scan already running. Does
    /// nothing when the switch is off or the app can't see the whole library.
    func start(for friend: Friend, context: ModelContext) {
        cancel()
        guard Self.isEnabled,
              PhotoLibraryService.shared.authorizationStatus() == .authorized else { return }

        friendID = friend.id
        activeFriend = friend
        activeContext = context
        phase = .local
        let gen = generation
        task = Task { await run(generation: gen) }
    }

    func cancel() {
        task?.cancel()
        task = nil
        generation += 1
        phase = .idle
        friendID = nil
        activeFriend = nil
        activeContext = nil
    }

    // MARK: - Scan

    private func run(generation gen: Int) async {
        defer { if gen == generation { phase = .done } }
        guard let friend = activeFriend else { return }

        // Loading the model blocks, so keep it off the main thread.
        guard let service = await Task.detached(operation: { try? FaceMatchingService() }).value,
              isCurrent(gen) else { return }

        var identity = friend.identity
        if identity.isEmpty {
            let sample = Array(friend.photoMatches.shuffled().prefix(8))
            let assets = Self.assets(withIDs: sample.map(\.assetID))
            let known = sample.compactMap { match in
                assets[match.assetID].map { (asset: $0, box: match.faceBoundingBox) }
            }
            identity = await service.embedKnownFaces(known)
            guard isCurrent(gen), !identity.isEmpty else { return }
            friend.identity = identity
            save()
        }

        // Pass 1 — photos on this device, taken since the last finished scan.
        let scanStart = Date()
        let known = Set(friend.photoMatches.map(\.assetID))
        let alreadyPending = Set(friend.pendingCloudIDs)
        let fresh = PhotoLibraryService.shared
            .fetchAssets(since: friend.lastScannedAt ?? friend.createdAt)
            .filter { !known.contains($0.localIdentifier) && !alreadyPending.contains($0.localIdentifier) }

        if !fresh.isEmpty {
            let local = await service.findFriend(identity: identity, in: fresh, allowNetwork: false) { face in
                Task { @MainActor in self.add([face], generation: gen) }
            }
            guard isCurrent(gen) else { return }
            add(local.found, generation: gen)
            guard local.completed else { return }
            friend.pendingCloudIDs.append(contentsOf: local.unloadedIDs)
        }
        friend.lastScannedAt = scanStart
        save()

        // Pass 2 — photos with no local copy. Done in small chunks, each one
        // recorded as it finishes, so quitting mid-way doesn't redo downloads.
        let pendingAssets = Self.assets(withIDs: friend.pendingCloudIDs)
        let stillKnown = Set(friend.photoMatches.map(\.assetID))
        let cloud = friend.pendingCloudIDs.compactMap { pendingAssets[$0] }
            .filter { !stillKnown.contains($0.localIdentifier) }
        // Photos deleted from the library since they were queued drop out here.
        friend.pendingCloudIDs = cloud.map(\.localIdentifier)
        save()
        guard !cloud.isEmpty else { return }

        phase = .cloud
        var index = 0
        while index < cloud.count {
            let chunk = Array(cloud[index..<min(index + Self.cloudChunkSize, cloud.count)])
            index += chunk.count
            let result = await service.findFriend(identity: identity, in: chunk, allowNetwork: true) { face in
                Task { @MainActor in self.add([face], generation: gen) }
            }
            guard isCurrent(gen) else { return }
            add(result.found, generation: gen)
            // Anything that still wouldn't load (offline, timed out) stays queued.
            friend.pendingCloudIDs.removeAll { result.resolvedIDs.contains($0) }
            save()
        }
    }

    private func isCurrent(_ gen: Int) -> Bool {
        gen == generation && !Task.isCancelled && activeFriend?.isDeleted == false
    }

    private func add(_ faces: [FoundFace], generation gen: Int) {
        guard gen == generation, let friend = activeFriend, !friend.isDeleted else { return }
        var known = Set(friend.photoMatches.map(\.assetID))
        let new = faces.filter { known.insert($0.assetID).inserted }
        guard !new.isEmpty else { return }
        friend.photoMatches.append(contentsOf: new.map {
            PhotoMatch(assetID: $0.assetID, faceBoundingBox: $0.faceBoundingBox)
        })
        save()
        Self.logger.info("Rescan added \(new.count) photo(s); album now \(friend.photoMatches.count)")
    }

    private func save() {
        try? activeContext?.save()
    }

    private static func assets(withIDs ids: [String]) -> [String: PHAsset] {
        var byID: [String: PHAsset] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
            byID[asset.localIdentifier] = asset
        }
        return byID
    }
}
