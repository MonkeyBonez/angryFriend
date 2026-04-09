import SwiftUI
import UIKit
import Photos
import SwiftData

struct ScanningView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext

    @Query private var savedFriends: [Friend]

    @State private var phase: ScanPhase = .idle
    @State private var scanTask: Task<Void, Never>? = nil
    @State private var earlyStartTriggered = false

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
        .onDisappear { scanTask?.cancel() }
    }

    // MARK: - Scan pipeline

    private func startScan() {
        earlyStartTriggered = false
        scanTask = Task {
            let seedImages = appState.seedImages

            // Feature 2: Pool fast-path — skip scan if pool already populated
            if appState.matchPool.count >= appState.cardCount {
                await runExtraction(pool: appState.matchPool)
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

            guard !Task.isCancelled else { return }

            // 4. Normal launch if early start didn't fire (not enough matches found)
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

            // 5. Pass 2: Scan iCloud photos in background (network enabled)
            //    scannedIDs returned from pass1 — no per-asset MainActor dispatch needed
            let currentPoolCount = appState.matchPool.count
            let remainingCap = FaceMatchingService.targetMatchCount - currentPoolCount
            let iCloudAssets = assets.filter { !pass1.scannedIDs.contains($0.localIdentifier) }
            guard !iCloudAssets.isEmpty, remainingCap > 0, !Task.isCancelled else { return }

            Task {
                do {
                    _ = try await matchingService.scanCameraRoll(
                        seedEmbeddings: seedEmbeddings,
                        assets: iCloudAssets,
                        matchCap: remainingCap,
                        allowNetwork: true,
                        onProgress: { _ in },
                        onMatch: { match in
                            Task { @MainActor in
                                appState.matchPool.append(match)
                            }
                        }
                    )
                } catch { }
            }
        }
    }

    // MARK: - Extraction (shared by early-start and normal path)

    private func runExtraction(pool: [MatchedAsset]) async {
        let needed = appState.cardCount

        // Sample from pool, excluding recently-used IDs for variety
        let available = pool.filter { !appState.usedAssetIDs.contains($0.asset.localIdentifier) }
        let source = available.count >= needed ? available : pool  // reset if pool exhausted
        let sampled = Array(source.shuffled().prefix(needed))

        // Mark sampled photos as used
        sampled.forEach { appState.usedAssetIDs.insert($0.asset.localIdentifier) }
        if available.count < needed {
            // Pool was exhausted; reset tracking so next round feels fresh
            appState.usedAssetIDs = Set(sampled.map { $0.asset.localIdentifier })
        }

        let extractionService = SubjectExtractionService.shared
        var cards: [GameCard] = []
        let angryIndex = Int.random(in: 0..<max(1, sampled.count))

        for (i, match) in sampled.enumerated() {
            guard !Task.isCancelled else { return }
            phase = .extracting(i + 1, sampled.count)

            guard let fullImage = await PhotoLibraryService.shared.loadImage(
                for: match.asset,
                targetSize: CGSize(width: 1024, height: 1024),
                allowNetwork: true
            ) else { continue }

            // Feature 3: Zoom-to-face mode
            let cutout: UIImage
            if appState.useZoomMode {
                cutout = await extractionService.extractSubjectAroundFace(
                    from: fullImage,
                    faceBoundingBox: match.faceBoundingBox
                )
            } else {
                cutout = await extractionService.extractSubject(from: fullImage)
            }
            cards.append(GameCard(image: cutout, isAngry: i == angryIndex))
        }

        guard cards.count >= 4 else {
            phase = .error("Subject extraction failed for too many photos. Try again.")
            return
        }

        appState.gameModel.setup(from: cards.shuffled())

        // Auto-save friend (new session only); dedup against existing friends by seed data
        if appState.currentFriend == nil {
            let stickerImage: UIImage?
            if let firstSeed = appState.seedImages.first {
                stickerImage = await SubjectExtractionService.shared.extractSubject(from: firstSeed)
            } else {
                stickerImage = nil
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

        // Dedup: if a saved friend has identical seed images, update them instead
        for friend in savedFriends where friend.seedImageData == seedData {
            if !stickerData.isEmpty { friend.stickerData = stickerData }
            let existingSet = Set(friend.matchedAssetIDs)
            friend.matchedAssetIDs.append(contentsOf: matchedIDs.filter { !existingSet.contains($0) })
            friend.lastScannedAt = Date()
            try? modelContext.save()
            appState.currentFriend = friend
            return
        }

        // New friend — auto-generate a name
        let name = savedFriends.isEmpty ? "Friend" : "Friend \(savedFriends.count + 1)"
        let friend = Friend(
            name: name,
            stickerData: stickerData,
            seedImageData: seedData,
            matchedAssetIDs: matchedIDs,
            useZoomMode: appState.useZoomMode
        )
        modelContext.insert(friend)
        try? modelContext.save()
        appState.currentFriend = friend
    }

    // MARK: - Phase helpers

    private var phaseIcon: String {
        switch phase {
        case .idle, .preparingSeed: return "face.smiling"
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
