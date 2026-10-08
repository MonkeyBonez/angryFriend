import BackgroundTasks
import Foundation
import Photos
import SwiftData
import UIKit
import os

/// Switches the scan's workers read between photos. Thread-safe so they can be
/// flipped from the main actor while the workers run elsewhere.
nonisolated final class ScanControl: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private var stopped = false

    func setHeld(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        held = value
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
    }

    var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    /// Don't start another photo yet: the foreground is snipping or identifying,
    /// or the phone is too hot.
    var mustWait: Bool {
        lock.lock(); defer { lock.unlock() }
        return held || ProcessInfo.processInfo.thermalState == .critical
    }

    /// Photos in flight at once. One when the phone is warm or saving power.
    var workers: Int {
        let info = ProcessInfo.processInfo
        return info.isLowPowerModeEnabled || info.thermalState == .serious ? 1 : 3
    }
}

/// Finds saved friends in the rest of the photo library and grows their albums.
///
/// One scan serves every friend: each photo is loaded and its faces embedded
/// once, then compared against everyone it's being checked for. Each round:
///
/// 1. New photos — anything added or edited since last time, so a fresh shot
///    shows up fast.
/// 2. Three older-photo turns: two go to the friend furthest behind (a friend
///    added after the walk started catches up on the photos it had already
///    passed), one to the shared walk back through the library. A turn with
///    nothing to do goes to the other kind.
/// 3. A few iCloud downloads, for photos whose original isn't on the phone and
///    whose on-phone copy couldn't rule them out.
///
/// Every step saves its cursor, so a scan cut short — backgrounded, killed, a
/// hold that outlasts the app — carries on where it stopped. It runs at utility
/// priority while the app is open (including during a game), pauses within a
/// photo while the foreground is snipping or identifying, gets about 30 s after
/// the app is backgrounded, and longer overnight via a `BGProcessingTask`.
/// Photos removed from an album by hand (`Friend.excludedIDs`) are never re-added.
@Observable
@MainActor
final class FriendRescanner {
    static let shared = FriendRescanner()

    enum Phase: Equatable {
        case idle
        case newPhotos
        case catchingUp(String)   // a friend's name
        case addingPicks(String)  // a new friend's picks that discovery stopped before reaching
        case tidying(String)      // re-checking a friend's album after the matching rules changed
        case walking
        case cloud
        case done
    }

    /// UserDefaults key behind the home screen's "auto-add new pics" switch.
    static let enabledKey = "autoScanNewPhotos"
    /// Also listed under `BGTaskSchedulerPermittedIdentifiers` in Info.plist.
    static let backgroundTaskID = "com.angryFriend.scan"

    private static let logger = Logger(subsystem: "com.angryFriend", category: "Rescan")
    private static let chunkSize = 24
    private static let cloudBatchSize = 24
    private static let maxCloudAttempts = 3

    private(set) var phase: Phase = .idle
    private(set) var holdCount = 0
    // For the home screen's status line; refreshed every round.
    private(set) var walkRemaining = 0
    private(set) var catchUpRemaining = 0
    private(set) var picksRemaining = 0
    private(set) var cloudWaiting = 0
    private(set) var isOffline = false

    /// Set while the processing screen waits for this friend's album to fill:
    /// every catch-up turn goes to them, and the scan runs at user-initiated
    /// priority until it's cleared.
    var focusFriendID: UUID? = nil

    @ObservationIgnored private var task: Task<Void, Never>? = nil
    @ObservationIgnored private var control = ScanControl()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var runPriority: TaskPriority = .utility
    @ObservationIgnored private var restartForPriority = false
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var backgroundRun: BGTask? = nil
    @ObservationIgnored private var libraryObserver: LibraryObserver? = nil
    @ObservationIgnored private var libraryChangeDebounce: Task<Void, Never>? = nil
    @ObservationIgnored private var checkedThisRun = 0
    /// Friends whose identity couldn't be rebuilt — skipped until next launch.
    @ObservationIgnored private var unusableFriendIDs: Set<UUID> = []
    /// Album tidy verdicts already reached this launch (friend → photo → keep?),
    /// so a tidy cut short by the background picks up where it was.
    @ObservationIgnored private var tidyVerdicts: [UUID: [String: Bool]] = [:]
    /// Friends whose faces the tidy already rebuilt this launch — kept as they
    /// are on a resume, so the verdicts above stay consistent.
    @ObservationIgnored private var rebuiltThisLaunch: Set<UUID> = []

    private var context: ModelContext { angryFriendApp.container.mainContext }
    private var library: PhotoLibraryService { PhotoLibraryService.shared }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    private static var canScan: Bool {
        #if DEBUG
        if DebugLaunch.scanSuspended { return false }
        #endif
        return isEnabled && PhotoLibraryService.shared.authorizationStatus() == .authorized
    }

    var isRunning: Bool { task != nil && !control.isStopped }

    /// While a scan is going there's still a chance of more photos turning up
    /// for `friend`; once it ends, the library has nothing more to give.
    func couldStillAdd(to friend: Friend) -> Bool {
        isRunning && !unusableFriendIDs.contains(friend.id)
    }

    // MARK: - Control

    /// Starts the scan unless it's already going. Cheap — call it whenever
    /// there might be something new: launch, foreground, tapping a friend, a
    /// change in the library.
    func ensureRunning() {
        if UIApplication.shared.applicationState == .active { endBackgroundTask() }
        guard Self.canScan else { return }
        observeLibrary()
        guard !isRunning else { return }
        start()
    }

    /// The switch was turned off.
    func stop() {
        control.stop()
        generation += 1
        task = nil
        phase = .idle
        endBackgroundTask()
        finishBackgroundRun(success: true)
    }

    /// The foreground needs the phone (cutting out cards, identifying a new
    /// friend): no new photo is started until every hold is released.
    func beginHold() {
        holdCount += 1
        control.setHeld(true)
        if holdCount == 1 { Self.logger.info("Scan paused for the foreground") }
    }

    func endHold() {
        holdCount = max(0, holdCount - 1)
        control.setHeld(holdCount > 0)
        if holdCount == 0 { Self.logger.info("Scan resumed") }
    }

    private func start() {
        generation += 1
        let gen = generation
        let control = ScanControl()
        control.setHeld(holdCount > 0)
        self.control = control
        runPriority = wantedPriority
        restartForPriority = false
        checkedThisRun = 0
        if backgroundRun == nil, UIApplication.shared.applicationState == .background { beginBackgroundTask() }
        task = Task(priority: runPriority) { await self.run(generation: gen, control: control) }
    }

    private func finished(generation gen: Int, control: ScanControl) {
        guard gen == generation else { return }   // superseded by stop() or a newer start()
        task = nil
        if restartForPriority, !control.isStopped {
            start()
            return
        }
        if control.isStopped { phase = .idle }
        Self.logger.info("Scan ended: \(self.checkedThisRun) photos checked\(control.isStopped ? " (stopped)" : "")")
        endBackgroundTask()
        finishBackgroundRun(success: !control.isStopped)
    }

    private func isCurrent(_ gen: Int, _ control: ScanControl) -> Bool {
        gen == generation && !control.isStopped && !Task.isCancelled
    }

    // MARK: - The loop

    private enum StepResult { case worked, nothingLeft, stopped }

    /// Who's being scanned for this round, and what each already has.
    private struct Round {
        var friends: [UUID: Friend]
        var templates: [UUID: FaceTemplate]
        var known: [UUID: Set<String>]   // photoMatches ∪ excludedIDs — never checked again
    }

    private func run(generation gen: Int, control: ScanControl) async {
        defer { finished(generation: gen, control: control) }

        let state = ScanState.load(in: context)
        guard hasWork(state) else {
            refreshCounts(state)
            phase = .done
            return
        }
        // Loading the model blocks, so keep it off the main thread.
        guard let service = await Task.detached(priority: .utility, operation: { try? FaceMatchingService() }).value,
              isCurrent(gen, control) else { return }

        Self.logger.info("Scan started (\(self.runPriority == .userInitiated ? "focused" : "background")): new photos after \(state.newestModifiedSeen), walk \(state.walkDone ? "done" : "at \(state.walkCursor)"), \(state.pendingCloudIDs.count) waiting for iCloud")

        while isCurrent(gen, control) {
            if wantedPriority != runPriority {
                restartForPriority = true
                return
            }

            guard let round = await prepareRound(state, service: service, generation: gen, control: control) else {
                phase = .done
                return
            }
            var worked = false

            // 1. New photos first: a fresh shot should show up fast.
            switch await forwardStep(round, state: state, service: service, generation: gen, control: control) {
            case .stopped: return
            case .worked: worked = true
            case .nothingLeft: break
            }

            // 2. A new friend's own picks that discovery didn't get to: the album
            // the user just made fills before anything older is looked at.
            switch await pickedStep(round, state: state, service: service, generation: gen, control: control) {
            case .stopped: return
            case .worked: worked = true
            case .nothingLeft: break
            }

            // 3. Two turns for whoever is furthest behind, one for the shared walk.
            // Picked once per round: counting what each friend has left is a
            // library query, and this runs on the main actor.
            let lagging = laggingFriend(round)
            let focused = lagging != nil && lagging?.id == focusFriendID
            for turn in 0..<3 {
                guard isCurrent(gen, control) else { return }
                let catchUpTurn = focused || turn < 2
                var result = StepResult.nothingLeft
                if catchUpTurn, let friend = lagging {
                    result = await catchUpStep(friend, round: round, state: state, service: service, generation: gen, control: control)
                }
                if result == .nothingLeft {
                    result = await walkStep(round, state: state, service: service, generation: gen, control: control)
                }
                if result == .nothingLeft, !catchUpTurn, let friend = lagging {
                    result = await catchUpStep(friend, round: round, state: state, service: service, generation: gen, control: control)
                }
                if result == .stopped { return }
                if result == .worked { worked = true }
            }

            // 4. A few iCloud downloads.
            switch await cloudStep(round, state: state, service: service, generation: gen, control: control) {
            case .stopped: return
            case .worked: worked = true
            case .nothingLeft: break
            }

            refreshCounts(state)
            if !worked {
                phase = .done
                Self.logger.info("Scan up to date\(state.pendingCloudIDs.isEmpty ? "" : "; \(state.pendingCloudIDs.count) waiting for iCloud (offline)")")
                return
            }
        }
    }

    /// Anything for the scan to do? Answered from cursors and counts alone, so
    /// a library change that brought nothing new doesn't load the face model.
    private func hasWork(_ state: ScanState) -> Bool {
        let friends = (try? context.fetch(FetchDescriptor<Friend>())) ?? []
        guard !friends.isEmpty else {
            // Nobody to look for. Keep the new-photos cursor current, so the
            // first friend's own catch-up covers the past rather than both.
            state.newestModifiedSeen = max(state.newestModifiedSeen, Date())
            save()
            return false
        }
        return friends.contains { $0.catchUpFloor == nil || $0.needsCatchUp || $0.hasPendingPicks || $0.identityVersion < Friend.currentIdentityVersion || $0.needsNotThemRecheck }
            || !state.walkDone
            || (!state.pendingCloudIDs.isEmpty && NetworkMonitor.shared.isOnline)
            || library.count(changedAfter: state.newestModifiedSeen) > 0
    }

    private func prepareRound(_ state: ScanState, service: FaceMatchingService, generation gen: Int, control: ScanControl) async -> Round? {
        let all = (try? context.fetch(FetchDescriptor<Friend>())) ?? []
        guard !all.isEmpty else { return nil }

        // Newcomers join the scan here. The shared walk covers everything older
        // than where it is now; their own catch-up covers the rest, back from
        // now to there. Photos added from here on reach them via new photos.
        let now = Date()
        for friend in all where friend.catchUpFloor == nil {
            friend.catchUpFloor = state.walkDone ? .distantPast : state.walkCursor
            friend.catchUpBefore = now
            Self.logger.info("\(friend.name) joined the scan; catching up from now back to \(friend.catchUpFloor!)")
        }
        save()

        // Friends saved before identities were stored, or under older matching
        // rules: rebuild their faces from the album and re-check it, once.
        guard await tidyAlbums(all, state: state, service: service, generation: gen, control: control) else { return nil }

        var round = Round(friends: [:], templates: [:], known: [:])
        for friend in all where Self.isAlive(friend) && !unusableFriendIDs.contains(friend.id) {
            guard let template = friend.template else { continue }
            round.friends[friend.id] = friend
            round.templates[friend.id] = template
            round.known[friend.id] = Set(friend.photoMatches.map(\.assetID) + friend.excludedIDs)
        }
        return round.friends.isEmpty ? nil : round
    }

    /// Once after the matching rules or the face model change
    /// (`Friend.currentIdentityVersion`):
    /// 1. Rebuilds every such friend's stored faces from their album — the
    ///    user's own picks come first in it — keeping the largest group's most
    ///    central faces, so a stranger's face that slipped in is left out.
    /// 2. Re-checks every photo in those albums against everyone's new faces
    ///    and drops what no longer passes: a face that looks more like another
    ///    friend, or like no one. Dropped photos aren't excluded; the scan may
    ///    bring one back only if it passes the same rule.
    /// 3. Walks the library again, since the old rules missed photos the new
    ///    ones find.
    /// All identities are rebuilt before any album is judged, so no album is
    /// compared against faces from the old rules (or an old model, whose
    /// embeddings mean nothing to the new one). False if the scan stopped
    /// part-way; whatever wasn't finished is redone next time.
    ///
    /// The same album check (step 2 alone) runs after the user marks faces
    /// "Not them": that person's other photos in the album go too.
    private func tidyAlbums(_ friends: [Friend], state: ScanState, service: FaceMatchingService, generation gen: Int, control: ScanControl) async -> Bool {
        let stale = friends.filter {
            Self.isAlive($0) && !unusableFriendIDs.contains($0.id)
                && ($0.identityVersion < Friend.currentIdentityVersion || $0.identity.isEmpty)
        }
        let notThem = friends.filter {
            Self.isAlive($0) && !unusableFriendIDs.contains($0.id) && !stale.contains($0) && $0.needsNotThemRecheck
        }
        guard !stale.isEmpty || !notThem.isEmpty else { return true }
        if !stale.isEmpty {
            Self.logger.info("Matching rules changed: rebuilding faces for \(stale.map(\.name).joined(separator: ", "))")
        }
        if !notThem.isEmpty {
            Self.logger.info("Re-checking albums against new \"Not them\" faces: \(notThem.map { "\($0.name) (\($0.negatives.count))" }.joined(separator: ", "))")
        }

        // 1. Faces, for every stale friend first. A friend whose new faces are
        //    already stored (a tidy cut short in step 2) keeps them.
        var rebuilt: Set<UUID> = []
        for friend in stale {
            if rebuiltThisLaunch.contains(friend.id), !friend.identity.isEmpty {
                rebuilt.insert(friend.id)
                continue
            }
            phase = .tidying(friend.name)
            let sample = Array(friend.photoMatches.prefix(24))
            let sampleAssets = Self.assets(withIDs: sample.map(\.assetID))
            let known = sample.compactMap { match in
                sampleAssets[match.assetID].map { (asset: $0, box: match.faceBoundingBox) }
            }
            let faces = await service.embedKnownFaces(known, limit: sample.count)
            guard isCurrent(gen, control) else { return false }
            let identity = FaceMatchingService.representativeFaces(faces)
            guard Self.isAlive(friend), !identity.isEmpty else {
                unusableFriendIDs.insert(friend.id)
                Self.logger.warning("Couldn't rebuild a face for \(friend.name); skipping them")
                continue
            }
            friend.identity = identity
            // "Not them" faces come from the old rules' model; they can't be compared with
            // the new one's. (The photos stay excluded; only the face memory goes.)
            if friend.identityVersion < Friend.currentIdentityVersion { friend.negatives = [] }
            rebuilt.insert(friend.id)
            rebuiltThisLaunch.insert(friend.id)
            Self.logger.info("Rebuilt \(friend.name)'s face from \(identity.count) of \(faces.count) faces in their first \(sample.count) photos")
        }
        save()

        // 2. Every album photo, against everyone the app knows. Friends whose
        //    faces couldn't be rebuilt aren't in `templates` (wrong model or rules).
        var templates: [UUID: FaceTemplate] = [:]
        for other in friends where Self.isAlive(other) && !unusableFriendIDs.contains(other.id) {
            let current = rebuilt.contains(other.id) || other.identityVersion >= Friend.currentIdentityVersion
            if current, let template = other.template { templates[other.id] = template }
        }
        for friend in stale.filter({ rebuilt.contains($0.id) }) + notThem {
            phase = .tidying(friend.name)
            let matches = friend.photoMatches
            let assets = Self.assets(withIDs: matches.map(\.assetID))
            var keep = Set(matches.map(\.assetID).filter { assets[$0] == nil })   // gone from the library: nothing to judge
            var someoneElse = 0, noOne = 0, noFace = 0
            var verdicts = tidyVerdicts[friend.id] ?? [:]
            for (id, kept) in verdicts where kept { keep.insert(id) }
            let toJudge = matches.filter { verdicts[$0.assetID] == nil }
            if !verdicts.isEmpty { Self.logger.info("Tidy \(friend.name): resuming, \(verdicts.count) photos already judged") }
            var index = 0
            while index < toJudge.count {
                guard isCurrent(gen, control) else { return false }
                if control.mustWait {
                    try? await Task.sleep(for: .milliseconds(300))
                    continue
                }
                let batch = toJudge[index..<min(index + control.workers, toJudge.count)]
                index += batch.count
                let checked = await withTaskGroup(of: (String, FaceEmbedding?).self, returning: [(String, FaceEmbedding?)].self) { group in
                    for match in batch {
                        guard let asset = assets[match.assetID] else { continue }
                        let id = match.assetID
                        let box = match.faceBoundingBox
                        group.addTask { (id, await service.embedKnownFaces([(asset: asset, box: box)], limit: 1).first) }
                    }
                    var results: [(String, FaceEmbedding?)] = []
                    for await result in group { results.append(result) }
                    return results
                }
                for (id, face) in checked {
                    guard let face else {
                        noFace += 1
                        keep.insert(id)
                        verdicts[id] = true
                        continue
                    }
                    let owner = FaceMatchingService.owner(of: face, among: templates)
                    verdicts[id] = owner == friend.id
                    switch owner {
                    case .some(let owner) where owner == friend.id:
                        keep.insert(id)
                    case .some(let owner):
                        someoneElse += 1
                        let ownerName = friends.first { $0.id == owner }?.name ?? "?"
                        Self.logger.info("Tidy \(friend.name): dropped \(id.prefix(8)), looks like \(ownerName)")
                    case .none:
                        noOne += 1
                        let why = templates[friend.id]?.rejects(face) == true ? "looks like a \"Not them\" face" : "matches no one"
                        Self.logger.info("Tidy \(friend.name): dropped \(id.prefix(8)), \(why)")
                    }
                }
                tidyVerdicts[friend.id] = verdicts
            }
            guard isCurrent(gen, control), Self.isAlive(friend) else { return false }
            let before = friend.photoMatches.count
            friend.photoMatches.removeAll { !keep.contains($0.assetID) }
            friend.identityVersion = Friend.currentIdentityVersion
            friend.notThemChecked = friend.negatives.count
            tidyVerdicts[friend.id] = nil
            save()
            Self.logger.info("Tidied \(friend.name)'s album: kept \(friend.photoMatches.count) of \(before) — \(someoneElse) looked more like another friend, \(noOne) no longer matched, \(noFace) had no face to check")
        }

        // 3. Walk the whole library again under the new rules (not for "Not them":
        //    the scan only ever adds, and it already turns those faces away).
        if !stale.isEmpty, friends.allSatisfy({ !Self.isAlive($0) || unusableFriendIDs.contains($0.id) || $0.identityVersion >= Friend.currentIdentityVersion }) {
            state.walkStartedAt = Date()
            state.walkBefore = nil
            state.walkDone = false
            for friend in friends where Self.isAlive(friend) { friend.catchUpBefore = friend.catchUpFloor }
            save()
            Self.logger.info("Albums tidied; walking the library again under the new rules")
        }
        return true
    }

    /// The friend with the most photos still to catch up on — the focus friend
    /// first, if they have any.
    private func laggingFriend(_ round: Round) -> Friend? {
        let behind = round.friends.values.filter { Self.isAlive($0) && $0.needsCatchUp }
        if let focusFriendID, let focus = behind.first(where: { $0.id == focusFriendID }) { return focus }
        return behind.max { remaining($0) < remaining($1) }
    }

    private func remaining(_ friend: Friend) -> Int {
        guard let before = friend.catchUpBefore, let floor = friend.catchUpFloor else { return 0 }
        return library.count(before: before, floor: floor)
    }

    // MARK: Steps

    /// Photos added or edited since last time, checked against everyone.
    private func forwardStep(_ round: Round, state: ScanState, service: FaceMatchingService, generation gen: Int, control: ScanControl) async -> StepResult {
        let step = library.stepForward(after: state.newestModifiedSeen, limit: Self.chunkSize)
        guard let next = step.next else { return .nothingLeft }
        Self.logger.debug("New photos: \(step.assets.count) changed after \(state.newestModifiedSeen)")
        phase = .newPhotos
        guard await check(step.assets, for: Array(round.friends.keys), round: round, state: state,
                          service: service, generation: gen, control: control) else { return .stopped }
        state.newestModifiedSeen = max(state.newestModifiedSeen, next)
        save()
        return .worked
    }

    /// Every friend's leftover picks, oldest friend first, in chunks. Checked
    /// against everyone, so one face still goes to one person; photos already
    /// in the album are skipped and iCloud-only picks join the iCloud queue.
    private func pickedStep(_ round: Round, state: ScanState, service: FaceMatchingService, generation gen: Int, control: ScanControl) async -> StepResult {
        let waiting = round.friends.values
            .filter { Self.isAlive($0) && $0.hasPendingPicks }
            .sorted { $0.createdAt < $1.createdAt }
        guard !waiting.isEmpty else { return .nothingLeft }
        for friend in waiting {
            while Self.isAlive(friend), friend.hasPendingPicks {
                guard isCurrent(gen, control) else { return .stopped }
                phase = .addingPicks(friend.name)
                picksRemaining = friend.pendingPickedIDs.count
                let batch = Array(friend.pendingPickedIDs.prefix(Self.chunkSize))
                let assets = Self.assets(withIDs: batch)   // a pick deleted since just drops out
                Self.logger.debug("Picks \(friend.name): \(batch.count) of \(friend.pendingPickedIDs.count)")
                guard await check(batch.compactMap { assets[$0] }, for: [friend.id], round: round, state: state,
                                  service: service, generation: gen, control: control) else { return .stopped }
                guard Self.isAlive(friend) else { break }
                friend.pendingPickedIDs.removeFirst(min(batch.count, friend.pendingPickedIDs.count))
                picksRemaining = friend.pendingPickedIDs.count
                save()
                if !friend.hasPendingPicks {
                    Self.logger.info("\(friend.name)'s picks all checked; album has \(friend.photoMatches.count)")
                }
            }
        }
        return .worked
    }

    /// One chunk of a friend's own walk back through what the shared walk had
    /// already passed when they joined.
    private func catchUpStep(_ friend: Friend, round: Round, state: ScanState, service: FaceMatchingService, generation gen: Int, control: ScanControl) async -> StepResult {
        guard let before = friend.catchUpBefore, let floor = friend.catchUpFloor, before > floor else { return .nothingLeft }
        phase = .catchingUp(friend.name)
        let step = library.stepBack(before: before, floor: floor == .distantPast ? nil : floor, limit: Self.chunkSize)
        Self.logger.debug("Catch-up \(friend.name): \(step.assets.count) photos before \(before)")
        guard let next = step.next else {
            friend.catchUpBefore = floor
            save()
            Self.logger.info("\(friend.name) caught up; album has \(friend.photoMatches.count)")
            return .worked
        }
        guard await check(step.assets, for: [friend.id], round: round, state: state,
                          service: service, generation: gen, control: control) else { return .stopped }
        guard Self.isAlive(friend) else { return .worked }
        friend.catchUpBefore = max(next, floor)
        save()
        return .worked
    }

    /// One chunk of the shared walk back through the library, checked against everyone.
    private func walkStep(_ round: Round, state: ScanState, service: FaceMatchingService, generation gen: Int, control: ScanControl) async -> StepResult {
        guard !state.walkDone else { return .nothingLeft }
        phase = .walking
        let step = library.stepBack(before: state.walkCursor, limit: Self.chunkSize)
        Self.logger.debug("Walk: \(step.assets.count) photos before \(state.walkCursor)")
        guard let next = step.next else {
            state.walkDone = true
            save()
            Self.logger.info("Walk reached the oldest photo")
            return .worked
        }
        guard await check(step.assets, for: Array(round.friends.keys), round: round, state: state,
                          service: service, generation: gen, control: control) else { return .stopped }
        state.walkBefore = next
        save()
        return .worked
    }

    /// Downloads a few photos whose originals are only in iCloud and checks them
    /// against everyone. A download that fails goes to the back of the queue;
    /// after three failures the photo is dropped.
    private func cloudStep(_ round: Round, state: ScanState, service: FaceMatchingService, generation gen: Int, control: ScanControl) async -> StepResult {
        guard !state.pendingCloudIDs.isEmpty else { return .nothingLeft }
        guard NetworkMonitor.shared.isOnline else {
            isOffline = true
            return .nothingLeft
        }
        isOffline = false
        phase = .cloud

        let batch = Array(state.pendingCloudIDs.prefix(Self.cloudBatchSize))
        let assets = Self.assets(withIDs: batch)
        let candidates: [ScanCandidate] = batch.compactMap { id in
            guard let asset = assets[id] else { return nil }   // deleted since it was queued
            let friendIDs = round.friends.keys.filter { !(round.known[$0]?.contains(id) ?? false) }
            return friendIDs.isEmpty ? nil : ScanCandidate(asset: asset, friendIDs: friendIDs)
        }

        var result = FriendsSearchResult()
        if !candidates.isEmpty {
            result = await service.findFriends(templates: round.templates, in: candidates, mode: .download, control: control) { friendID, face in
                Task { @MainActor in FriendRescanner.shared.add(face, to: friendID) }
            }
            guard gen == generation else { return .stopped }
            for (friendID, faces) in result.found {
                faces.forEach { add($0, to: friendID) }
            }
            checkedThisRun += result.checkedIDs.count
        }

        // Not reached because the scan stopped: stay at the front.
        let attempted = Set(candidates.map(\.asset.localIdentifier))
        let failed = Set(result.failedIDs)
        let unreached = batch.filter { attempted.contains($0) && !result.checkedIDs.contains($0) && !failed.contains($0) }
        var retries = state.cloudRetries
        var retryLater: [String] = []
        for id in batch {
            if failed.contains(id) {
                let attempts = retries[id, default: 0] + 1
                if attempts >= Self.maxCloudAttempts {
                    retries[id] = nil
                    Self.logger.warning("Giving up on iCloud photo \(id.prefix(8)) after \(attempts) failed downloads")
                } else {
                    retries[id] = attempts
                    retryLater.append(id)
                }
            } else if !unreached.contains(id) {
                retries[id] = nil
            }
        }
        state.pendingCloudIDs = unreached + state.pendingCloudIDs.dropFirst(batch.count) + retryLater
        state.cloudRetries = retries
        save()
        return isCurrent(gen, control) ? .worked : .stopped
    }

    /// Checks photos on the phone for `friendIDs`, skipping friends who already
    /// have (or have excluded) a photo and photos already waiting for iCloud.
    /// False if the scan stopped part-way — the caller then leaves its cursor
    /// where it was, so the chunk is done again next time.
    private func check(_ assets: [PHAsset], for friendIDs: [UUID], round: Round, state: ScanState, service: FaceMatchingService, generation gen: Int, control: ScanControl) async -> Bool {
        let waiting = Set(state.pendingCloudIDs)
        let candidates: [ScanCandidate] = assets.compactMap { asset in
            let id = asset.localIdentifier
            guard !waiting.contains(id) else { return nil }
            let unchecked = friendIDs.filter { !(round.known[$0]?.contains(id) ?? false) }
            return unchecked.isEmpty ? nil : ScanCandidate(asset: asset, friendIDs: unchecked)
        }
        guard !candidates.isEmpty else { return true }

        // Matches land as they're found, so an album being waited on fills live.
        let result = await service.findFriends(templates: round.templates, in: candidates, mode: .local, control: control) { friendID, face in
            Task { @MainActor in FriendRescanner.shared.add(face, to: friendID) }
        }
        guard isCurrent(gen, control) else { return false }
        for (friendID, faces) in result.found {
            faces.forEach { add($0, to: friendID) }
        }
        checkedThisRun += result.checkedIDs.count + result.cloudIDs.count
        guard result.completed else { return false }

        let queued = Set(state.pendingCloudIDs)
        state.pendingCloudIDs += (result.cloudIDs + result.failedIDs).filter { !queued.contains($0) }
        return true
    }

    private func add(_ face: FoundFace, to friendID: UUID) {
        let descriptor = FetchDescriptor<Friend>(predicate: #Predicate { $0.id == friendID })
        guard let friend = try? context.fetch(descriptor).first, Self.isAlive(friend),
              !friend.excludedIDs.contains(face.assetID),
              !friend.photoMatches.contains(where: { $0.assetID == face.assetID }) else { return }
        friend.photoMatches.append(PhotoMatch(assetID: face.assetID, faceBoundingBox: face.faceBoundingBox))
        save()
        Self.logger.info("Added a photo to \(friend.name); album now \(friend.photoMatches.count)")
    }

    private func refreshCounts(_ state: ScanState) {
        walkRemaining = state.walkDone ? 0 : library.count(before: state.walkCursor)
        let friends = (try? context.fetch(FetchDescriptor<Friend>())) ?? []
        if case .catchingUp(let name) = phase, let friend = friends.first(where: { $0.name == name && $0.needsCatchUp }) {
            catchUpRemaining = remaining(friend)
        } else {
            catchUpRemaining = friends.filter(\.needsCatchUp).reduce(0) { $0 + remaining($1) }
        }
        cloudWaiting = state.pendingCloudIDs.count
        picksRemaining = friends.filter(Self.isAlive).reduce(0) { $0 + $1.pendingPickedIDs.count }
    }

    /// User-initiated while someone's waiting on the processing screen, or while
    /// a new friend's picks are still being added; utility otherwise.
    private var wantedPriority: TaskPriority {
        if focusFriendID != nil { return .userInitiated }
        let friends = (try? context.fetch(FetchDescriptor<Friend>())) ?? []
        return friends.contains { Self.isAlive($0) && $0.hasPendingPicks } ? .userInitiated : .utility
    }

    /// One line for the home screen, or nil when there's nothing to say.
    var statusLine: String? {
        guard Self.isEnabled else { return nil }
        var parts: [String] = []
        if isRunning, holdCount > 0 {
            parts.append("paused while snipping")
        } else {
            switch phase {
            case .idle: return nil
            case .newPhotos: parts.append("checking new photos")
            case .catchingUp(let name): parts.append("catching up \(name) · \(catchUpRemaining.formatted()) left")
            case .addingPicks(let name): parts.append("adding \(name)'s picks · \(picksRemaining.formatted()) left")
            case .tidying(let name): parts.append("tidying \(name)'s album")
            case .walking: parts.append("checking older photos · \(walkRemaining.formatted()) left")
            case .cloud: parts.append("downloading from iCloud")
            case .done: parts.append(cloudWaiting > 0 && isOffline ? "offline" : "up to date")
            }
        }
        if cloudWaiting > 0 { parts.append("\(cloudWaiting.formatted()) waiting for iCloud") }
        return parts.joined(separator: " · ")
    }

    // MARK: - App lifecycle

    /// Extra time once the app is in the background — usually enough to finish
    /// the chunk in hand. When it runs out the scan stops; every cursor is
    /// already saved.
    private func beginBackgroundTask() {
        endBackgroundTask()
        let control = self.control
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "friend-scan") { [weak self] in
            Self.logger.info("Background time expired; scan will resume later")
            control.stop()
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// Called from `didFinishLaunching` — iOS requires the handler registered
    /// before launch completes.
    static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskID, using: .main) { task in
            MainActor.assumeIsolated {
                FriendRescanner.shared.runBackgroundTask(task)
            }
        }
    }

    /// The app was sent to the background: ask for the usual ~30 s to finish
    /// the chunk in hand, and for a long run later.
    func appDidEnterBackground() {
        if isRunning, backgroundRun == nil { beginBackgroundTask() }
        scheduleBackgroundRun()
    }

    /// Asks iOS for a long run later, typically overnight while charging. The
    /// run also picks up the day's new photos, so it's asked for whenever the
    /// switch is on.
    private func scheduleBackgroundRun() {
        guard Self.canScan else { return }
        let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskID)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false
        do {
            try BGTaskScheduler.shared.submit(request)
            Self.logger.info("Background run requested")
        } catch {
            Self.logger.warning("Couldn't request a background run: \(error.localizedDescription)")
        }
    }

    private func runBackgroundTask(_ bgTask: BGTask) {
        Self.logger.info("Background run started")
        guard Self.canScan else {
            bgTask.setTaskCompleted(success: true)
            return
        }
        backgroundRun = bgTask
        if !isRunning { start() }
        bgTask.expirationHandler = {
            Task { @MainActor in FriendRescanner.shared.backgroundRunExpired() }
        }
    }

    /// iOS took the long run's time back. iOS can start that run while the app
    /// is open (charging, a debugger attached) and expire it seconds later —
    /// then the scan is the foreground's and carries on; only a scan that's
    /// really in the background stops.
    private func backgroundRunExpired() {
        if UIApplication.shared.applicationState != .active { control.stop() }
        finishBackgroundRun(success: false)
    }

    private func finishBackgroundRun(success: Bool) {
        guard let run = backgroundRun else { return }
        backgroundRun = nil
        Self.logger.info("Background run finished (\(success ? "done" : "out of time")): \(self.checkedThisRun) photos checked")
        run.setTaskCompleted(success: success)
        scheduleBackgroundRun()
    }

    /// Restarts the scan a few seconds after the library changes — a photo
    /// taken, saved or synced while the app is open.
    private func observeLibrary() {
        guard libraryObserver == nil else { return }
        let observer = LibraryObserver {
            Task { @MainActor in FriendRescanner.shared.libraryDidChange() }
        }
        PHPhotoLibrary.shared().register(observer)
        libraryObserver = observer
    }

    private func libraryDidChange() {
        libraryChangeDebounce?.cancel()
        libraryChangeDebounce = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, UIApplication.shared.applicationState == .active else { return }
            ensureRunning()
        }
    }

    // MARK: - Helpers

    private func save() {
        try? context.save()
    }

    private static func isAlive(_ friend: Friend) -> Bool {
        !friend.isDeleted && friend.modelContext != nil
    }

    private static func assets(withIDs ids: [String]) -> [String: PHAsset] {
        var byID: [String: PHAsset] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
            byID[asset.localIdentifier] = asset
        }
        return byID
    }
}

private final class LibraryObserver: NSObject, PHPhotoLibraryChangeObserver {
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange()
    }
}
