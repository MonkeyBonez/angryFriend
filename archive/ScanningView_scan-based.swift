import SwiftUI
import UIKit
import Photos
import SwiftData
import os

private let logger = Logger(subsystem: "com.angryFriend", category: "ScanningView")

// TEMP: Set to true to re-enable iCloud photo scanning in background passes.
private let iCloudScanEnabled = false

struct ScanningView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext

    @Query private var savedFriends: [Friend]

    @State private var phase: ScanPhase = .idle
    @State private var scanTask: Task<Void, Never>? = nil
    @State private var earlyStartTriggered = false
    @State private var localPassCompleted = false

    private static let logger = Logger(subsystem: "com.angryFriend", category: "ScanningView")

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                Image(systemName: phaseIcon)
                    .font(.system(size: 60))
                    .foregroundStyle(phaseColor)
                    .symbolEffect(.pulse, isActive: isActive)

                Text(phaseTitle)
                    .font(.title2.bold())

                Text(phaseSubtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                if case .scanning(let p) = phase {
                    VStack(spacing: 8) {
                        ProgressView(value: Double(p.scanned), total: Double(max(p.total, 1)))
                            .tint(.orange)
                            .padding(.horizontal, 32)
                        Text("Scanned \(p.scanned) / \(p.total) • \(p.matchesFound) matches")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if case .extracting(let cur, let tot) = phase {
                    VStack(spacing: 8) {
                        ProgressView(value: Double(cur), total: Double(max(tot, 1)))
                            .tint(.blue)
                            .padding(.horizontal, 32)
                        Text("Extracting subject \(cur) of \(tot)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if case .error = phase {
                    Button("Go Back") {
                        scanTask?.cancel()
                        appState.seedImages = []
                        appState.screen = .seedPicker
                    }
                    .font(.headline)
                    .padding()
                    .background(.orange)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                Spacer()
            }
        }
        .onAppear { startScan() }
    }

    // MARK: - Scan pipeline

    private func startScan() {
        earlyStartTriggered = false
        scanTask = Task {
            let seedImages = appState.seedImages

            // The foreground scan owns PHImageManager exclusively. A background scan
            // for saved friends may be running (it launches on every scene-active), and
            // two scans competing for PHImageManager can starve the foreground one to a
            // standstill. Stop it before we start — this covers BOTH the fast-path below
            // and the full-scan path (the latter previously never cancelled it).
            appState.backgroundScanTask?.cancel()
            appState.backgroundScanTask = nil
            appState.isICloudScanning = false

            // Fast-path — pool already populated (e.g. "Play Again", saved friend, manual pick)
            if appState.matchPool.count >= appState.cardCount {
                // Manual picks and rehydrated saved friends carry no face boxes. Recover
                // the friend's identity so cutouts isolate the right person: prefer seed
                // embeddings, else discover the most-recurring face in a random sample.
                var references: [FaceEmbedding] = []
                var matcher: FaceMatchingService? = nil
                if appState.matchPool.contains(where: { $0.faceBoundingBox == .zero }),
                   let service = try? FaceMatchingService() {
                    phase = .identifying
                    if !seedImages.isEmpty {
                        references = (try? await service.extractSeedEmbeddings(from: seedImages)) ?? []
                    }
                    if references.isEmpty {
                        references = await service.dominantIdentityEmbeddings(
                            in: appState.matchPool.map(\.asset)
                        )
                    }
                    matcher = references.isEmpty ? nil : service
                }

                phase = .extracting(0, appState.cardCount)
                await runExtraction(pool: appState.matchPool, references: references, matcher: matcher)

                // Relaunch background resumption after extraction, claiming the task slot.
                if appState.currentFriend?.localScanCompleted == false ||
                   appState.currentFriend?.iCloudPassCompleted == false {
                    let task = Task { await self.resumeBackgroundScan(seedImages: seedImages) }
                    appState.backgroundScanTask = task
                }
                return
            }

            guard !seedImages.isEmpty else {
                phase = .error("No seed photos selected.")
                return
            }

            // 1. Extract seed embeddings
            phase = .preparingSeed
            let matchingService: FaceMatchingService
            do {
                matchingService = try FaceMatchingService()
            } catch {
                phase = .error(error.localizedDescription)
                return
            }

            let seedEmbeddings: [FaceEmbedding]
            do {
                seedEmbeddings = try await matchingService.extractSeedEmbeddings(from: seedImages)
            } catch {
                phase = .error(error.localizedDescription)
                return
            }

            // 2. Fetch assets
            phase = .fetchingAssets
            let assets = await PhotoLibraryService.shared.fetchAllCameraRollAssets()
            guard !assets.isEmpty else {
                phase = .error("Your camera roll is empty.")
                return
            }

            // 3. Pass 1: Scan local (on-device) photos first — fast, no network
            phase = .scanning(ScanProgress(scanned: 0, total: assets.count, matchesFound: 0))

            let pass1: FaceMatchingService.ScanResult
            do {
                pass1 = try await matchingService.scanCameraRoll(
                    seedEmbeddings: seedEmbeddings,
                    assets: assets,
                    matchCap: FaceMatchingService.targetMatchCount,
                    onProgress: { progress in
                        Task { @MainActor in
                            if case .scanning = self.phase {
                                self.phase = .scanning(progress)
                            }
                            // Save local scan progress date for resumption
                            if progress.scanned > 0 && progress.scanned <= assets.count && progress.scanned % 50 == 0 {
                                if let friend = self.appState.currentFriend {
                                    friend.localLastScannedDate = assets[progress.scanned - 1].creationDate
                                    try? self.modelContext.save()
                                }
                            }
                        }
                    },
                    onMatch: { match in
                        Task { @MainActor in
                            appState.matchPool.append(match)
                            if !self.earlyStartTriggered &&
                               appState.matchPool.count >= appState.cardCount + 4 {
                                self.earlyStartTriggered = true
                                let pool = appState.matchPool.sorted { $0.similarity > $1.similarity }
                                Task { await self.runExtraction(pool: pool) }
                            }
                        }
                    }
                )
            } catch {
                if !earlyStartTriggered {
                    phase = .error("Scan failed: \(error.localizedDescription)")
                }
                return
            }

            // Mark local scan complete
            localPassCompleted = true
            if let friend = appState.currentFriend {
                friend.localScanCompleted = true
                friend.localLastScannedDate = nil
                try? modelContext.save()
            }

            // 4. Launch iCloud pass BEFORE extraction
            let currentPoolCount = appState.matchPool.count
            let remainingCap = FaceMatchingService.targetMatchCount - currentPoolCount
            let iCloudAssets = assets.filter { !pass1.scannedIDs.contains($0.localIdentifier) }

            if iCloudAssets.isEmpty || remainingCap <= 0 || !iCloudScanEnabled {
                markICloudComplete()
            } else {
                launchICloudPass(
                    service: matchingService,
                    seedEmbeddings: seedEmbeddings,
                    assets: iCloudAssets,
                    matchCap: remainingCap
                )
            }

            // 5. Normal launch if early start didn't fire
            if !earlyStartTriggered {
                let pool = appState.matchPool.sorted { $0.similarity > $1.similarity }
                guard pool.count >= 4 else {
                    phase = .error(
                        "Only \(pool.count) photo\(pool.count == 1 ? "" : "s") matched — need at least 4.\n\nTry a clearer front-facing seed photo, or add more seed photos."
                    )
                    return
                }
                await runExtraction(pool: pool)
            }
        }
    }

    private func markICloudComplete() {
        if let friend = appState.currentFriend {
            friend.iCloudPassCompleted = true
            try? modelContext.save()
        }
    }

    // MARK: - Extraction (shared by early-start and normal path)

    private func runExtraction(
        pool: [MatchedAsset],
        references: [FaceEmbedding] = [],
        matcher: FaceMatchingService? = nil
    ) async {
        let needed = appState.cardCount

        let available = pool.filter { !appState.usedAssetIDs.contains($0.asset.localIdentifier) }
        let source = available.count >= needed ? available : pool
        let sampled = Array(source.shuffled().prefix(needed))

        sampled.forEach { appState.usedAssetIDs.insert($0.asset.localIdentifier) }
        if available.count < needed {
            appState.usedAssetIDs = Set(sampled.map { $0.asset.localIdentifier })
        }

        phase = .extracting(0, sampled.count)

        let extractionService = SubjectExtractionService.shared
        var cards: [GameCard] = []
        let angryIndex = Int.random(in: 0..<Swift.max(1, sampled.count))

        let extracted = await withTaskGroup(of: (Int, UIImage?).self, returning: [(Int, UIImage)].self) { group in
            var results: [(Int, UIImage)] = []
            var iter = sampled.enumerated().makeIterator()
            var pending = 0

            while pending < 3, let (i, match) = iter.next() {
                group.addTask { await (i, Self.loadAndExtract(match: match, service: extractionService, references: references, matcher: matcher)) }
                pending += 1
            }

            for await (i, image) in group {
                pending -= 1
                if let image { results.append((i, image)) }
                await MainActor.run {
                    self.phase = .extracting(results.count, sampled.count)
                }
                if let (nextI, nextMatch) = iter.next() {
                    group.addTask { await (nextI, Self.loadAndExtract(match: nextMatch, service: extractionService, references: references, matcher: matcher)) }
                    pending += 1
                }
            }
            return results
        }

        for (i, image) in extracted {
            cards.append(GameCard(image: image, isAngry: i == angryIndex))
        }

        guard cards.count >= 4 else {
            phase = .error("Subject extraction failed for too many photos. Try again.")
            return
        }

        appState.gameModel.setup(from: cards.shuffled())

        if appState.currentFriend == nil {
            let stickerImage: UIImage?
            if let firstSeed = appState.seedImages.first {
                stickerImage = await SubjectExtractionService.shared.extractSubject(from: firstSeed)
            } else {
                // Manual pick has no seed — the extracted cards are already subject cutouts.
                stickerImage = extracted.first?.1
            }
            autoSaveFriend(stickerImage: stickerImage)
        }

        appState.screen = .game
    }

    // MARK: - Auto-save helper

    private func autoSaveFriend(stickerImage: UIImage?) {
        let stickerData = stickerImage?.jpegData(compressionQuality: 0.8) ?? Data()
        let seedData = appState.seedImages.compactMap { $0.jpegData(compressionQuality: 0.8) }
        let matchedIDs = appState.matchPool.map { $0.asset.localIdentifier }

        // Manual picks have no seed images — an empty seedData would make every
        // manually-created friend "match" every other one, so skip dedupe entirely.
        if seedData.isEmpty {
            let name = savedFriends.isEmpty ? "Friend" : "Friend \(savedFriends.count + 1)"
            let friend = Friend(
                name: name,
                stickerData: stickerData,
                seedImageData: [],
                matchedAssetIDs: matchedIDs
            )
            // No seed embeddings exist for this friend, so background scan resumption
            // can never run — mark both passes complete so it never tries.
            friend.localScanCompleted = true
            friend.iCloudPassCompleted = true
            modelContext.insert(friend)
            try? modelContext.save()
            appState.currentFriend = friend
            return
        }

        for friend in savedFriends where friend.seedImageData == seedData {
            if !stickerData.isEmpty { friend.stickerData = stickerData }
            let existingSet = Set(friend.matchedAssetIDs)
            friend.matchedAssetIDs.append(contentsOf: matchedIDs.filter { !existingSet.contains($0) })
            friend.lastScannedAt = Date()
            if localPassCompleted { friend.localScanCompleted = true }
            try? modelContext.save()
            appState.currentFriend = friend
            return
        }

        let name = savedFriends.isEmpty ? "Friend" : "Friend \(savedFriends.count + 1)"
        let friend = Friend(
            name: name,
            stickerData: stickerData,
            seedImageData: seedData,
            matchedAssetIDs: matchedIDs
        )
        friend.localScanCompleted = localPassCompleted
        modelContext.insert(friend)
        try? modelContext.save()
        appState.currentFriend = friend
    }

    // MARK: - Load + extract helper (runs off main actor)

    private static func loadAndExtract(
        match: MatchedAsset,
        service: SubjectExtractionService,
        references: [FaceEmbedding] = [],
        matcher: FaceMatchingService? = nil
    ) async -> UIImage? {
        let targetSize = CGSize(width: 1024, height: 1024)

        // 1. Fast local path — no network, loadImage's internal timeout handles any hang.
        // 2. iCloud fallback — loadImage has a 20s abandonment timeout so this never hangs forever.
        var image = await PhotoLibraryService.shared.loadImage(
            for: match.asset, targetSize: targetSize, allowNetwork: false
        )
        if image == nil {
            image = await PhotoLibraryService.shared.loadImage(
                for: match.asset, targetSize: targetSize, allowNetwork: true
            )
        }
        guard let image else { return nil }

        // Zero box = manual pick / saved friend: locate the friend's face so the
        // extraction crops and cuts out the right person.
        var faceBox = match.faceBoundingBox
        if faceBox == .zero, let matcher, !references.isEmpty {
            faceBox = await matcher.bestFaceBox(in: image, matching: references) ?? .zero
        }
        return await service.extractSubject(from: image, faceBoundingBox: faceBox)
    }

    // MARK: - Background scan resumption (local + iCloud)

    /// Resumes any incomplete scans for the current friend.
    /// 1. New local photos since lastScannedAt (fast, small set)
    /// 2. Remaining local photos from localLastScannedDate (if local scan was interrupted)
    /// 3. Remaining iCloud photos from iCloudLastScannedDate
    private func resumeBackgroundScan(seedImages: [UIImage]) async {
        guard !seedImages.isEmpty else {
            Self.logger.warning("resumeBackgroundScan: no seed images")
            return
        }
        guard !appState.isICloudScanning else {
            Self.logger.info("resumeBackgroundScan: another scan already running")
            return
        }
        guard !Task.isCancelled else { return }

        appState.isICloudScanning = true

        // Ensure the flag and toast are always cleared when we exit, for any reason.
        defer {
            appState.isICloudScanning = false
            appState.iCloudScanToast = nil
        }

        let service: FaceMatchingService
        do {
            service = try FaceMatchingService()
        } catch {
            Self.logger.error("resumeBackgroundScan: FaceMatchingService init failed: \(error.localizedDescription)")
            return
        }

        let embeddings: [FaceEmbedding]
        do {
            embeddings = try await service.extractSeedEmbeddings(from: seedImages)
        } catch {
            Self.logger.error("resumeBackgroundScan: seed embedding failed: \(error.localizedDescription)")
            return
        }

        guard !Task.isCancelled else { return }

        let friendName = appState.currentFriend?.name ?? "Friend"
        appState.iCloudScanToast = ICloudScanToast(friendName: friendName, scanned: 0, total: 0)

        let allAssets = await PhotoLibraryService.shared.fetchAllCameraRollAssets()
        guard !allAssets.isEmpty else {
            Self.logger.warning("resumeBackgroundScan: no camera roll assets")
            return
        }

        guard !Task.isCancelled else { return }

        // Phase A: Scan new local photos since last scan date (fast, small set)
        let newLocalAssets = await PhotoLibraryService.shared.fetchAssets(since: appState.currentFriend?.lastScannedAt ?? .distantPast)
        if !newLocalAssets.isEmpty && !Task.isCancelled {
            Self.logger.info("resumeBackgroundScan: scanning \(newLocalAssets.count) new local photos")
            appState.iCloudScanToast = ICloudScanToast(friendName: friendName, scanned: 0, total: newLocalAssets.count)
            let _ = try? await service.scanCameraRoll(
                seedEmbeddings: embeddings,
                assets: newLocalAssets,
                matchCap: nil,
                onProgress: { p in
                    Task { @MainActor in
                        self.appState.iCloudScanToast = ICloudScanToast(friendName: friendName, scanned: p.scanned, total: p.total)
                    }
                },
                onMatch: { match in
                    Task { @MainActor in
                        self.appState.matchPool.append(match)
                        self.persistMatch(match)
                    }
                }
            )
        }

        guard !Task.isCancelled else { return }

        // Phase B: Resume incomplete local scan (if interrupted mid-pass)
        if appState.currentFriend?.localScanCompleted == false {
            let resumeDate = appState.currentFriend?.localLastScannedDate
            let remainingLocal: [PHAsset]
            if let resumeDate {
                remainingLocal = allAssets.filter { ($0.creationDate ?? .distantPast) < resumeDate }
            } else {
                remainingLocal = allAssets
            }

            if !remainingLocal.isEmpty && !Task.isCancelled {
                Self.logger.info("resumeBackgroundScan: resuming local scan, \(remainingLocal.count) remaining")
                appState.iCloudScanToast = ICloudScanToast(friendName: friendName, scanned: 0, total: remainingLocal.count)
                let _ = try? await service.scanCameraRoll(
                    seedEmbeddings: embeddings,
                    assets: remainingLocal,
                    matchCap: nil,
                    onProgress: { p in
                        Task { @MainActor in
                            self.appState.iCloudScanToast = ICloudScanToast(friendName: friendName, scanned: p.scanned, total: p.total)
                            if p.scanned > 0 && p.scanned <= remainingLocal.count && p.scanned % 50 == 0 {
                                self.appState.currentFriend?.localLastScannedDate = remainingLocal[p.scanned - 1].creationDate
                                try? self.modelContext.save()
                            }
                        }
                    },
                    onMatch: { match in
                        Task { @MainActor in
                            self.appState.matchPool.append(match)
                            self.persistMatch(match)
                        }
                    }
                )
            }

            if !Task.isCancelled {
                appState.currentFriend?.localScanCompleted = true
                try? modelContext.save()
            }
        }

        guard !Task.isCancelled else { return }

        // Phase C: Resume incomplete iCloud scan
        if iCloudScanEnabled && appState.currentFriend?.iCloudPassCompleted == false {
            let resumeDate = appState.currentFriend?.iCloudLastScannedDate
            let remainingCloud: [PHAsset]
            if let resumeDate {
                remainingCloud = allAssets.filter { ($0.creationDate ?? .distantPast) < resumeDate }
            } else {
                remainingCloud = allAssets
            }

            if !remainingCloud.isEmpty && !Task.isCancelled {
                Self.logger.info("resumeBackgroundScan: resuming iCloud scan, \(remainingCloud.count) remaining")
                appState.iCloudScanToast = ICloudScanToast(friendName: friendName, scanned: 0, total: remainingCloud.count)
                let _ = try? await service.scanCameraRoll(
                    seedEmbeddings: embeddings,
                    assets: remainingCloud,
                    matchCap: nil,
                    allowNetwork: true,
                    onProgress: { p in
                        Task { @MainActor in
                            self.appState.iCloudScanToast = ICloudScanToast(friendName: friendName, scanned: p.scanned, total: p.total)
                            if p.scanned > 0 && p.scanned <= remainingCloud.count && p.scanned % 50 == 0 {
                                self.appState.currentFriend?.iCloudLastScannedDate = remainingCloud[p.scanned - 1].creationDate
                                try? self.modelContext.save()
                            }
                        }
                    },
                    onMatch: { match in
                        Task { @MainActor in
                            self.appState.matchPool.append(match)
                            self.persistMatch(match)
                        }
                    }
                )
            }

            if !Task.isCancelled {
                markICloudComplete()
            }
        }

        guard !Task.isCancelled else { return }

        // Done — show completion toast (defer clears isICloudScanning + toast after sleep)
        appState.currentFriend?.lastScannedAt = Date()
        try? modelContext.save()

        appState.iCloudScanToast = ICloudScanToast(
            friendName: friendName,
            scanned: 1, total: 1, isComplete: true
        )
        try? await Task.sleep(for: .seconds(2))
        // defer will run here and clear the toast — no separate nil assignment needed.
    }

    /// Persists a single match to the current friend's matchedAssetIDs.
    private func persistMatch(_ match: MatchedAsset) {
        guard let friend = appState.currentFriend else { return }
        let id = match.asset.localIdentifier
        if !friend.matchedAssetIDs.contains(id) {
            friend.matchedAssetIDs.append(id)
            try? modelContext.save()
        }
    }

    // MARK: - iCloud pass 2 (first scan, launched as independent task)

    private func launchICloudPass(
        service: FaceMatchingService,
        seedEmbeddings: [FaceEmbedding],
        assets: [PHAsset],
        matchCap: Int
    ) {
        let friendName = appState.currentFriend?.name ?? "Friend"
        appState.iCloudScanToast = ICloudScanToast(
            friendName: friendName,
            scanned: 0,
            total: assets.count
        )
        appState.isICloudScanning = true

        // Cancel any prior task and claim the single-owner slot.
        appState.backgroundScanTask?.cancel()
        let task = Task {
            defer {
                Task { @MainActor in
                    self.appState.isICloudScanning = false
                }
            }
            do {
                _ = try await service.scanCameraRoll(
                    seedEmbeddings: seedEmbeddings,
                    assets: assets,
                    matchCap: matchCap,
                    allowNetwork: true,
                    onProgress: { progress in
                        Task { @MainActor in
                            self.appState.iCloudScanToast = ICloudScanToast(
                                friendName: friendName,
                                scanned: progress.scanned,
                                total: progress.total
                            )
                            if progress.scanned > 0 && progress.scanned <= assets.count && progress.scanned % 50 == 0 {
                                if let friend = self.appState.currentFriend {
                                    friend.iCloudLastScannedDate = assets[progress.scanned - 1].creationDate
                                    try? self.modelContext.save()
                                }
                            }
                        }
                    },
                    onMatch: { match in
                        Task { @MainActor in
                            self.appState.matchPool.append(match)
                            self.persistMatch(match)
                        }
                    }
                )
            } catch { }

            guard !Task.isCancelled else { return }

            await MainActor.run {
                self.markICloudComplete()
                self.appState.iCloudScanToast = ICloudScanToast(
                    friendName: friendName,
                    scanned: assets.count,
                    total: assets.count,
                    isComplete: true
                )
            }
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run {
                if self.appState.iCloudScanToast?.isComplete == true {
                    self.appState.iCloudScanToast = nil
                }
            }
        }
        appState.backgroundScanTask = task
    }

    // MARK: - Phase helpers

    private var phaseIcon: String {
        switch phase {
        case .idle, .preparingSeed: return "face.smiling"
        case .identifying: return "person.crop.circle.badge.questionmark"
        case .fetchingAssets: return "photo.stack"
        case .scanning: return "magnifyingglass.circle"
        case .extracting: return "scissors"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var phaseColor: Color {
        switch phase {
        case .error: return .red
        case .extracting: return .blue
        default: return .orange
        }
    }

    private var isActive: Bool {
        switch phase {
        case .error: return false
        default: return true
        }
    }

    private var phaseTitle: String {
        switch phase {
        case .idle: return "Getting Ready"
        case .preparingSeed: return "Reading Seed Photo"
        case .identifying: return "Finding Your Friend"
        case .fetchingAssets: return "Loading Camera Roll"
        case .scanning: return "Finding Your Friend"
        case .extracting: return "Cutting Out Photos"
        case .error: return "Oops"
        }
    }

    private var phaseSubtitle: String {
        switch phase {
        case .idle: return ""
        case .preparingSeed: return "Extracting face fingerprint from your seed photo…"
        case .identifying: return "Looking for the same face across your photos…"
        case .fetchingAssets: return "Reading your camera roll…"
        case .scanning: return "Scanning for matching faces. This may take a moment."
        case .extracting: return "Removing backgrounds to make game cards…"
        case .error(let msg): return msg
        }
    }
}

// MARK: - Phase enum

private enum ScanPhase: Equatable {
    case idle
    case preparingSeed
    case identifying
    case fetchingAssets
    case scanning(ScanProgress)
    case extracting(Int, Int)
    case error(String)
}

extension ScanProgress: Equatable {
    static func == (lhs: ScanProgress, rhs: ScanProgress) -> Bool {
        lhs.scanned == rhs.scanned && lhs.matchesFound == rhs.matchesFound
    }
}
