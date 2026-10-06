import Foundation
import Photos
import SwiftData
import UIKit
import os

/// Looks through the camera roll for new photos of a saved friend and grows
/// their album with what it finds. Runs when a friend is picked to play, and
/// catches up on every friend when the app comes to the foreground.
///
/// Two passes: photos already on the device first (fast, no downloads), then the
/// ones that only exist in iCloud. Lives on `AppState` rather than in a view so a
/// scan keeps going across the processing screen, the game and the result.
///
/// Progress is written to the friend as it happens — every match, and a cursor
/// after every chunk — so a scan cut short by the app being backgrounded or
/// killed resumes from where it stopped, never from the start.
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
    private static let localChunkSize = 24
    private static let cloudChunkSize = 12
    /// A catch-up pass re-checks every friend; don't do it more often than this.
    private static let catchUpInterval: TimeInterval = 5 * 60

    private(set) var phase: Phase = .idle
    private(set) var friendID: UUID? = nil

    private var task: Task<Void, Never>? = nil
    // Bumped on every start/cancel so a superseded scan can't touch state.
    private var generation = 0
    private var activeFriend: Friend? = nil
    private var activeContext: ModelContext? = nil
    /// Friends still waiting their turn in a catch-up pass.
    private var queue: [Friend] = []
    private var lastCatchUp: Date? = nil
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    private static var canScan: Bool {
        isEnabled && PhotoLibraryService.shared.authorizationStatus() == .authorized
    }

    var isRunning: Bool { phase == .local || phase == .cloud }

    func isScanning(for friend: Friend) -> Bool {
        friendID == friend.id && isRunning
    }

    /// Starts a scan for `friend`, replacing any scan already running. Does
    /// nothing when the switch is off or the app can't see the whole library.
    func start(for friend: Friend, context: ModelContext) {
        cancel()
        guard Self.canScan else { return }
        begin(friend, context: context)
    }

    /// Picks up where any earlier scan left off, for every friend with work
    /// outstanding: unseen photos since their cursor, or iCloud photos still
    /// queued. Runs one friend at a time; a play-triggered scan takes over.
    func catchUp(friends: [Friend], context: ModelContext, ignoringThrottle: Bool = false) {
        guard !isRunning, Self.canScan, !friends.isEmpty else { return }
        if !ignoringThrottle, let last = lastCatchUp,
           Date().timeIntervalSince(last) < Self.catchUpInterval { return }
        lastCatchUp = Date()

        queue = friends.filter { friend in
            !friend.pendingCloudIDs.isEmpty
                || !PhotoLibraryService.shared.fetchAssets(since: friend.lastScannedAt ?? friend.createdAt).isEmpty
        }
        guard !queue.isEmpty else { return }
        Self.logger.info("Catch-up: \(self.queue.count) friend(s) have new photos to check")
        activeContext = context
        startNext()
    }

    func cancel() {
        task?.cancel()
        task = nil
        generation += 1
        phase = .idle
        friendID = nil
        activeFriend = nil
        activeContext = nil
        queue = []
        endBackgroundTask()
    }

    // MARK: - Lifecycle

    private func begin(_ friend: Friend, context: ModelContext) {
        friendID = friend.id
        activeFriend = friend
        activeContext = context
        phase = .local
        beginBackgroundTask()
        let gen = generation
        task = Task { await run(generation: gen) }
    }

    private func startNext() {
        guard let context = activeContext, !queue.isEmpty else { return }
        let friend = queue.removeFirst()
        guard !friend.isDeleted else { startNext(); return }
        begin(friend, context: context)
    }

    private func finish(generation gen: Int) {
        guard gen == generation else { return }
        phase = .done
        endBackgroundTask()
        startNext()
    }

    /// Asks iOS for extra time when the app is sent to the background mid-scan —
    /// usually enough to finish the current chunk and write the cursor. When it
    /// runs out the scan is cancelled; whatever was saved is picked up next time.
    private func beginBackgroundTask() {
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "friend-rescan") { [weak self] in
            Task { @MainActor in
                Self.logger.info("Background time expired; scan will resume next launch")
                self?.cancel()
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - Scan

    private func run(generation gen: Int) async {
        defer { finish(generation: gen) }
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

        // Pass 1 — photos on this device, taken since the cursor. Oldest first,
        // in chunks; the cursor moves up after each one, so an interrupted pass
        // resumes at the chunk it was on rather than re-checking everything.
        let scanStart = Date()
        let known = Set(friend.photoMatches.map(\.assetID))
        let alreadyPending = Set(friend.pendingCloudIDs)
        let fresh = Array(PhotoLibraryService.shared
            .fetchAssets(since: friend.lastScannedAt ?? friend.createdAt)
            .filter { !known.contains($0.localIdentifier) && !alreadyPending.contains($0.localIdentifier) }
            .reversed())

        if !fresh.isEmpty {
            Self.logger.info("Local pass: \(fresh.count) new photo(s) to check")
        }
        var index = 0
        while index < fresh.count {
            let chunk = Array(fresh[index..<min(index + Self.localChunkSize, fresh.count)])
            index += chunk.count
            let local = await service.findFriend(identity: identity, in: chunk, allowNetwork: false) { face in
                Task { @MainActor in self.add([face], generation: gen) }
            }
            guard isCurrent(gen) else { return }
            add(local.found, generation: gen)
            guard local.completed else { return }
            friend.pendingCloudIDs.append(contentsOf: local.unloadedIDs)
            // A second back from the newest photo checked, so a burst of shots
            // sharing that second isn't skipped on resume (known IDs dedupe).
            // Never moves backwards: imported photos with old shot dates sort
            // first and must not drag the cursor into the past.
            if let newest = chunk.last?.creationDate {
                let cursor = newest.addingTimeInterval(-1)
                friend.lastScannedAt = max(friend.lastScannedAt ?? friend.createdAt, cursor)
            }
            save()
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

        Self.logger.info("Cloud pass: \(cloud.count) photo(s) to download and check")
        phase = .cloud
        index = 0
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
