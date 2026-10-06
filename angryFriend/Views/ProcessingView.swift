import SwiftUI
import UIKit
import Photos
import SwiftData
import os

private let logger = Logger(subsystem: "com.angryFriend", category: "ProcessingView")

struct ProcessingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Query private var savedFriends: [Friend]

    @State private var phase: ProcessPhase = .idle
    @State private var task: Task<Void, Never>? = nil
    /// Finished cutouts, shown as they land so the wait doubles as a preview.
    @State private var previews: [UIImage] = []
    /// Set by "Play with N now" to stop waiting on the rescan for more photos.
    @State private var playWithWhatWeHave = false

    var body: some View {
        ZStack {
            // Background sheet and dots come from ContentView.

            VStack(spacing: 0) {
                Spacer()

                if case .error(let message) = phase {
                    errorState(message)
                } else {
                    workingState
                }

                Spacer()
            }
            .padding(.horizontal, 30)
        }
        .onAppear {
            Haptics.warmUp()
            start()
        }
        .onDisappear { task?.cancel() }
    }

    // MARK: - Working

    private var workingState: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(.white)
                    .frame(width: 112, height: 112)
                    .overlay(Circle().stroke(StickerTheme.ink, lineWidth: 3))
                    .hardShadow(StickerTheme.ink.opacity(0.35), x: 5, y: 6)

                Image(systemName: phaseIcon)
                    .font(.system(size: 46, weight: .bold))
                    .foregroundStyle(phaseColor)
                    .contentTransition(.symbolEffect(.replace))
            }
            .wiggling(true, amount: 6, speed: 0.85)

            StickerText(text: phaseTitle, size: 22, fill: .white, strokeWidth: 1.6, drop: 2)
                .padding(.top, 22)

            Text(phaseSubtitle)
                .font(.sticker(12.5, .medium))
                .foregroundStyle(StickerTheme.ink.opacity(0.75))
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .frame(height: 34)

            CandyProgressBar(progress: progressFraction, stripe: phaseColor)
                .frame(width: 214)
                .padding(.top, 6)

            Text(progressCaption)
                .font(.sticker(12, .bold))
                .foregroundStyle(StickerTheme.ink)
                .padding(.top, 12)
                .contentTransition(.numericText())

            if case .findingPhotos(let found, _) = phase {
                findingActions(found: found)
                    .padding(.top, 22)
            } else {
                previewStrip
                    .padding(.top, 26)
                    .frame(height: 46)
            }
        }
    }

    /// Ways out of the wait for more photos: start short-handed, or leave.
    private func findingActions(found: Int) -> some View {
        VStack(spacing: 12) {
            if found >= 4 {
                Button("Play with \(found) now") {
                    Haptics.press()
                    playWithWhatWeHave = true
                }
                .buttonStyle(StickerButtonStyle(background: StickerTheme.pink, size: 14, fullWidth: false))
            }

            Button("Go Back") {
                Haptics.press()
                task?.cancel()
                appState.currentFriend = nil
                appState.screen = .home
            }
            .buttonStyle(StickerButtonStyle(background: .white, foreground: StickerTheme.ink, size: 14, fullWidth: false))
        }
    }

    /// The most recent finished cutouts, newest last, each popping in on arrival.
    private var previewStrip: some View {
        HStack(spacing: 8) {
            ForEach(Array(previews.suffix(5).enumerated()), id: \.offset) { index, image in
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 38, height: 38)
                    .background(StickerTheme.tile(index))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(StickerTheme.ink, lineWidth: 2))
                    .hardShadow(StickerTheme.ink, x: 2, y: 2)
                    .rotationEffect(.degrees(StickerTheme.lean(index)))
                    .transition(.scale(scale: 0.2).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.6), value: previews.count)
    }

    // MARK: - Error

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 22)
                    .fill(.white)
                    .frame(width: 104, height: 104)
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(StickerTheme.ink, lineWidth: 3))
                    .hardShadow(StickerTheme.ink.opacity(0.35), x: 4, y: 5)

                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(StickerTheme.flame)
            }
            .rotationEffect(.degrees(-4))
            .popIn(from: 0.5)

            StickerText(text: "OOPS", size: 30, fill: StickerTheme.flame, strokeWidth: 2)
                .padding(.top, 20)

            Text(message)
                .font(.sticker(13, .medium))
                .foregroundStyle(StickerTheme.ink)
                .multilineTextAlignment(.center)
                .padding(16)
                .frame(maxWidth: .infinity)
                .stickerCard(cornerRadius: 14, lineWidth: 2)
                .padding(.top, 20)

            Button("Go Back") {
                Haptics.press()
                task?.cancel()
                appState.pendingPhotoIDs = []
                appState.currentFriend = nil
                appState.screen = .home
            }
            .buttonStyle(StickerButtonStyle(background: StickerTheme.blue))
            .padding(.top, 24)
        }
        .onAppear { Haptics.warn() }
    }

    // MARK: - Pipeline

    private func start() {
        // Every real round passes through here; the emoji demo never does.
        appState.isDemoRound = false
        task = Task {
            if let friend = appState.currentFriend {
                await runReplay(for: friend)
            } else {
                await runNewFriend()
            }
        }
    }

    /// New friend: discover who the recurring person is across ALL picked photos,
    /// then extract cutouts for this round and save the friend's full album.
    private func runNewFriend() async {
        let identifiers = appState.pendingPhotoIDs
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var assets: [PHAsset] = []
        fetched.enumerateObjects { asset, _, _ in assets.append(asset) }

        guard !assets.isEmpty else {
            phase = .error("Couldn't load the photos you picked.")
            return
        }

        phase = .identifying(0, assets.count)
        let service: FaceMatchingService
        do {
            service = try FaceMatchingService()
        } catch {
            phase = .error(error.localizedDescription)
            return
        }

        let discovery = await service.discoverFriendIdentity(in: assets) { done, total in
            Task { @MainActor in self.phase = .identifying(done, total) }
        }
        guard Task.isCancelled == false else { return }

        guard discovery.matches.count >= 4 else {
            phase = .error(
                "Only found the same person in \(discovery.matches.count) of \(assets.count) photos — need at least 4.\n\nTry picking photos where your friend's face is clearly visible."
            )
            return
        }

        let needed = appState.cardCount
        let sampled = Array(discovery.matches.shuffled().prefix(needed))
        appState.usedPhotoIDs = Set(sampled.map { $0.asset.localIdentifier })

        phase = .extracting(0, sampled.count)
        let extracted = await Self.extractAll(sampled) { done, total, image in
            Task { @MainActor in
                self.phase = .extracting(done, total)
                if let image {
                    self.previews.append(image)
                    Haptics.tick()
                }
            }
        }
        guard Task.isCancelled == false else { return }

        guard extracted.count >= 4 else {
            phase = .error("Cutting out photos failed for too many of them. Try again.")
            return
        }

        setupGame(from: extracted)

        // Cover: prefer a photo with only the friend in it — a genuinely solo shot —
        // so the friend's card in the carousel never shows anyone else. Verify each
        // candidate cutout with the face model before committing to it, in case
        // extraction produced a crop with no clearly detectable face.
        let coverImage = await Self.pickCoverImage(from: discovery.matches, alreadyExtracted: extracted)

        let name = savedFriends.isEmpty ? "Friend" : "Friend \(savedFriends.count + 1)"
        let friend = Friend(
            name: name,
            stickerData: coverImage?.jpegData(compressionQuality: 0.85) ?? Data(),
            photoMatches: discovery.matches.map { PhotoMatch(assetID: $0.asset.localIdentifier, faceBoundingBox: $0.faceBoundingBox) }
        )
        // What later rescans match new photos against, and where they start from.
        friend.identity = discovery.identity
        friend.lastScannedAt = Date()
        modelContext.insert(friend)
        try? modelContext.save()
        appState.currentFriend = friend
        appState.pendingPhotoIDs = []

        Haptics.done()
        appState.screen = .game
    }

    /// Replay for an existing friend: resample from the already-known album — no
    /// identity discovery needed, the face box for every photo is already stored.
    private func runReplay(for friend: Friend) async {
        let needed = appState.cardCount

        // Not enough photos for a full grid yet: give the rescan a chance to find
        // more before dealing. Once there are enough the game starts and the scan
        // carries on behind it.
        while friend.photoMatches.count < needed,
              appState.rescanner.isScanning(for: friend),
              !playWithWhatWeHave {
            phase = .findingPhotos(friend.photoMatches.count, needed)
            try? await Task.sleep(for: .milliseconds(250))
            guard Task.isCancelled == false else { return }
        }

        let available = friend.photoMatches.filter { !appState.usedPhotoIDs.contains($0.assetID) }
        let source = available.count >= needed ? available : friend.photoMatches
        let sampled = Array(source.shuffled().prefix(needed))

        guard sampled.count >= 4 else {
            phase = .error("This friend doesn't have enough photos saved to play.")
            return
        }

        appState.usedPhotoIDs = available.count >= needed
            ? appState.usedPhotoIDs.union(sampled.map(\.assetID))
            : Set(sampled.map(\.assetID))

        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: sampled.map(\.assetID), options: nil)
        var assetsByID: [String: PHAsset] = [:]
        fetched.enumerateObjects { asset, _, _ in assetsByID[asset.localIdentifier] = asset }

        let pairs: [FriendPhotoMatch] = sampled.compactMap { match in
            guard let asset = assetsByID[match.assetID] else { return nil }
            return FriendPhotoMatch(asset: asset, faceBoundingBox: match.faceBoundingBox, isSoloFace: false)
        }

        guard pairs.count >= 4 else {
            phase = .error("Some of this friend's photos are missing from your library. Try picking new photos.")
            return
        }

        phase = .extracting(0, pairs.count)
        let extracted = await Self.extractAll(pairs) { done, total, image in
            Task { @MainActor in
                self.phase = .extracting(done, total)
                if let image {
                    self.previews.append(image)
                    Haptics.tick()
                }
            }
        }
        guard Task.isCancelled == false else { return }

        guard extracted.count >= 4 else {
            phase = .error("Cutting out photos failed for too many of them. Try again.")
            return
        }

        setupGame(from: extracted)
        Haptics.done()
        appState.screen = .game
    }

    // MARK: - Game setup

    private func setupGame(from extracted: [(assetID: String, image: UIImage)]) {
        let angryIndex = Int.random(in: 0..<extracted.count)
        let cards = extracted.enumerated().map { i, entry in
            GameCard(image: entry.image, isAngry: i == angryIndex)
        }
        appState.gameModel.setup(from: cards.shuffled())
    }

    // MARK: - Concurrent extraction

    /// `onProgress` also hands back each finished cutout so the UI can show the
    /// pile growing — it's the same work, just reported as it lands.
    private static func extractAll(
        _ matches: [FriendPhotoMatch],
        onProgress: @escaping @Sendable (Int, Int, UIImage?) -> Void
    ) async -> [(assetID: String, image: UIImage)] {
        await withTaskGroup(of: (Int, String, UIImage?).self, returning: [(assetID: String, image: UIImage)].self) { group in
            var results: [(Int, String, UIImage)] = []
            var iterator = matches.enumerated().makeIterator()
            var pending = 0

            while pending < 3, let (i, match) = iterator.next() {
                group.addTask { (i, match.asset.localIdentifier, await loadAndExtract(asset: match.asset, box: match.faceBoundingBox)) }
                pending += 1
            }

            for await (i, assetID, image) in group {
                pending -= 1
                if let image { results.append((i, assetID, image)) }
                onProgress(results.count, matches.count, image)
                if let (nextI, nextMatch) = iterator.next() {
                    group.addTask { (nextI, nextMatch.asset.localIdentifier, await loadAndExtract(asset: nextMatch.asset, box: nextMatch.faceBoundingBox)) }
                    pending += 1
                }
            }

            return results.sorted { $0.0 < $1.0 }.map { (assetID: $0.1, image: $0.2) }
        }
    }

    // MARK: - Cover selection

    /// Tries solo-face matches first (a clean shot with no one else to mask out),
    /// then any other match, extracting each candidate and verifying with the face
    /// model that the resulting cutout still shows a real face before accepting it.
    /// Reuses an already-extracted card's image when the candidate is one of them.
    private static func pickCoverImage(
        from matches: [FriendPhotoMatch],
        alreadyExtracted: [(assetID: String, image: UIImage)]
    ) async -> UIImage? {
        let solo = matches.filter(\.isSoloFace)
        let rest = matches.filter { !$0.isSoloFace }
        let candidates = Array((solo + rest).prefix(10))

        for candidate in candidates {
            let image: UIImage?
            if let cached = alreadyExtracted.first(where: { $0.assetID == candidate.asset.localIdentifier }) {
                image = cached.image
            } else {
                image = await loadAndExtract(asset: candidate.asset, box: candidate.faceBoundingBox)
            }
            if let image, FaceMatchingService.hasDetectableFace(in: image) {
                return image
            }
        }
        return nil
    }

    private static func loadAndExtract(asset: PHAsset, box: CGRect) async -> UIImage? {
        let targetSize = CGSize(width: 1024, height: 1024)
        var image = await PhotoLibraryService.shared.loadImage(for: asset, targetSize: targetSize, allowNetwork: false)
        if image == nil {
            image = await PhotoLibraryService.shared.loadImage(for: asset, targetSize: targetSize, allowNetwork: true)
        }
        guard let image else { return nil }
        return await SubjectExtractionService.shared.extractSubject(from: image, faceBoundingBox: box)
    }

    // MARK: - Phase helpers

    private var friendLabel: String {
        let name = appState.currentFriend?.name ?? ""
        return name.isEmpty ? "your friend" : name
    }

    private var progressFraction: Double {
        switch phase {
        case .identifying(let done, let total), .extracting(let done, let total), .findingPhotos(let done, let total):
            return total > 0 ? Double(done) / Double(total) : 0
        case .idle, .error:
            return 0
        }
    }

    private var progressCaption: String {
        switch phase {
        case .idle: return "warming up…"
        case .identifying(let done, let total): return "checked \(done) of \(total)"
        case .extracting(let done, let total): return "\(done) of \(total) cut out"
        case .findingPhotos(let found, let needed): return "found \(found) of \(needed)"
        case .error: return ""
        }
    }

    private var phaseIcon: String {
        switch phase {
        case .idle: return "face.smiling"
        case .identifying: return "magnifyingglass"
        case .extracting: return "scissors"
        case .findingPhotos: return "photo.on.rectangle.angled"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var phaseColor: Color {
        switch phase {
        case .error: return StickerTheme.flame
        case .extracting: return StickerTheme.pink
        default: return StickerTheme.blue
        }
    }

    private var phaseTitle: String {
        switch phase {
        case .idle: return "GETTING READY"
        case .identifying: return "WHO'S THAT?"
        case .extracting: return "SNIP SNIP"
        case .findingPhotos: return "LOOKING AROUND"
        case .error: return "OOPS"
        }
    }

    private var phaseSubtitle: String {
        switch phase {
        case .idle: return "shuffling the deck…"
        case .identifying: return "spotting the face that keeps showing up"
        case .extracting: return "cutting \(friendLabel) out of every photo"
        case .findingPhotos: return "finding photos of \(friendLabel)…"
        case .error(let msg): return msg
        }
    }
}

// MARK: - Phase enum

private enum ProcessPhase: Equatable {
    case idle
    case identifying(Int, Int)
    case extracting(Int, Int)
    case findingPhotos(Int, Int)   // found so far, needed for a full grid
    case error(String)
}
