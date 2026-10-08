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
    /// How many photos are being cut out for this round.
    @State private var cardsToCut = 0

    // New friend: named while the face is found, saved as soon as it's known.
    /// Locked on appear, so leaving (which empties the roster) doesn't flip the layout mid-transition.
    @State private var lockedNewFriendFlow: Bool? = nil
    @State private var nameDraft = ""
    @FocusState private var nameFocused: Bool
    @State private var defaultName = "Friend"
    @State private var committedFriend: Friend? = nil
    @State private var discoveredMatches: [FriendPhotoMatch] = []
    @State private var coverImage: UIImage? = nil
    @State private var deckReady = false
    @State private var showDiscardConfirm = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Background sheet and dots come from ContentView.

            if case .error(let message) = phase {
                VStack(spacing: 0) {
                    Spacer()
                    errorState(message)
                    Spacer()
                }
                .padding(.horizontal, 30)
            } else if isNewFriendFlow {
                newFriendState
            } else {
                VStack(spacing: 0) {
                    closeBar
                    Spacer()
                    workingState
                    Spacer()
                }
                .padding(.horizontal, 30)
            }
        }
        .onAppear {
            Haptics.warmUp()
            lockedNewFriendFlow = appState.roster.isEmpty
            start()
            if appState.roster.isEmpty {
                // Focusing mid-transition doesn't take; wait for the screen to land.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { nameFocused = true }
            }
        }
        // Once the friend is saved the task carries on to give them a sticker,
        // even if they've already gone home or started playing.
        .onDisappear { if committedFriend == nil { task?.cancel() } }
        .onChange(of: nameDraft) { _, _ in
            guard let friend = committedFriend else { return }
            friend.name = storedName
            try? modelContext.save()
        }
        .confirmationDialog(
            "Discard \(buttonName)?",
            isPresented: $showDiscardConfirm,
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive, action: discardFriend)
            Button("Keep", role: .cancel) {}
        } message: {
            Text("They won't be saved. The photos stay in your library.")
        }
    }

    // MARK: - New friend

    private var isNewFriendFlow: Bool { lockedNewFriendFlow ?? appState.roster.isEmpty }
    private var trimmedName: String { nameDraft.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// What the buttons call them: their name, or "Friend" until one is typed.
    private var buttonName: String { trimmedName.isEmpty ? "Friend" : trimmedName }
    /// What gets saved: their name, or "Friend N" when none was typed.
    private var storedName: String { trimmedName.isEmpty ? defaultName : trimmedName }

    private var newFriendState: some View {
        VStack(spacing: 0) {
            closeBar
                .padding(.horizontal, 30)

            ScrollView {
                VStack(spacing: 0) {
                    newFriendBadge
                        .padding(.top, 18)

                    StickerText(text: newFriendTitle, size: 22, fill: .white, strokeWidth: 1.6, drop: 2)
                        .padding(.top, 22)

                    Text(newFriendSubtitle)
                        .font(.sticker(12.5, .medium))
                        .foregroundStyle(StickerTheme.ink.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)

                    Text("THEIR NAME")
                        .font(.sticker(10.5, .black))
                        .foregroundStyle(StickerTheme.ink.opacity(0.6))
                        .padding(.top, 22)

                    StickerNameField(text: $nameDraft, focused: $nameFocused, placeholder: "type a name")
                        .padding(.top, 7)

                    if committedFriend == nil {
                        // Until the face is settled there's something to wait for.
                        VStack(spacing: 12) {
                            CandyProgressBar(progress: progressFraction, stripe: phaseColor)
                                .frame(width: 214)
                            Text(progressCaption)
                                .font(.sticker(12, .bold))
                                .foregroundStyle(StickerTheme.ink)
                                .contentTransition(.numericText())
                        }
                        .padding(.top, 26)
                        .transition(.opacity)
                    } else {
                        // After that, the cutouts landing are the only sign of work.
                        previewStrip
                            .frame(height: 46)
                            .padding(.top, 26)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 30)
                .padding(.bottom, 20)
                .animation(.spring(response: 0.4, dampingFraction: 0.75), value: committedFriend != nil)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)

            // Outside the scroll view, so the keyboard pushes them up instead of hiding them.
            VStack(spacing: 12) {
                Button(action: playNow) {
                    Text("Play with Angry \(buttonName)")
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .buttonStyle(StickerButtonStyle(background: StickerTheme.flame))
                .disabled(!deckReady)
                .opacity(deckReady ? 1 : 0.45)

                Button(action: saveAndGoHome) {
                    Text("Save \(buttonName)")
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .buttonStyle(StickerButtonStyle(background: .white, foreground: StickerTheme.ink))
                .disabled(committedFriend == nil)
                .opacity(committedFriend == nil ? 0.45 : 1)
            }
            .padding(.horizontal, 30)
            .padding(.top, 8)
            .padding(.bottom, 14)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: deckReady)
        }
    }

    /// Before the face is known: today's working circle. Once it's known but
    /// before the cover is cut: a dashed space for the sticker. Then the sticker.
    private var newFriendBadge: some View {
        ZStack {
            if let coverImage {
                Image(uiImage: coverImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 112, height: 112)
                    .background(StickerTheme.tile(0))
                    .clipShape(Circle())
                    .overlay(Circle().stroke(.white, lineWidth: 4))
                    .overlay(Circle().stroke(StickerTheme.ink, lineWidth: 2.5).padding(-4))
                    .hardShadow(StickerTheme.ink.opacity(0.35), x: 4, y: 6)
                    .rotationEffect(.degrees(-3))
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            } else {
                ZStack {
                    if committedFriend == nil {
                        Circle()
                            .fill(.white)
                            .overlay(Circle().stroke(StickerTheme.ink, lineWidth: 3))
                            .hardShadow(StickerTheme.ink.opacity(0.35), x: 5, y: 6)
                    } else {
                        Circle()
                            .fill(Color.white.opacity(0.55))
                            .overlay(
                                Circle().strokeBorder(StickerTheme.ink.opacity(0.65),
                                                      style: StrokeStyle(lineWidth: 2.5, dash: [7, 6]))
                            )
                    }
                    Image(systemName: phaseIcon)
                        .font(.system(size: 46, weight: .bold))
                        .foregroundStyle(phaseColor)
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: 112, height: 112)
                .wiggling(true, amount: 6, speed: 0.85)
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.6), value: coverImage != nil)
    }

    private var newFriendTitle: String {
        if deckReady { return "ALL SET" }
        return committedFriend == nil ? "WHO'S THAT?" : "SNIP SNIP"
    }

    private var newFriendSubtitle: String {
        if deckReady { return "\(buttonName)'s deck is ready" }
        if committedFriend == nil { return "spotting the face that keeps showing up" }
        return "cutting \(buttonName) out of \(cardsToCut) photos"
    }

    // MARK: - Close

    private var closeBar: some View {
        HStack {
            Button {
                Haptics.press()
                if committedFriend == nil {
                    cancelToHome()
                } else {
                    showDiscardConfirm = true
                }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(StickerCircleButtonStyle(diameter: 32))
            .accessibilityLabel(committedFriend == nil ? "Cancel" : "Discard \(buttonName)")

            Spacer()
        }
        .padding(.top, 6)
    }

    // MARK: - Working (replays)

    private var workingState: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(.white)
                    .frame(width: 112, height: 112)
                    .overlay(Circle().stroke(StickerTheme.ink, lineWidth: 3))
                    .hardShadow(StickerTheme.ink.opacity(0.35), x: 5, y: 6)

                if appState.roster.count > 1 {
                    MiniStickerFan(friends: appState.roster, size: 40, maxShown: 3)
                } else {
                    Image(systemName: phaseIcon)
                        .font(.system(size: 46, weight: .bold))
                        .foregroundStyle(phaseColor)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .wiggling(true, amount: 6, speed: 0.85)

            StickerText(text: phaseTitle, size: 22, fill: .white, strokeWidth: 1.6, drop: 2)
                .padding(.top, 22)

            Text(phaseSubtitle)
                .font(.sticker(12.5, .medium))
                .foregroundStyle(StickerTheme.ink.opacity(0.75))
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .frame(minHeight: 34)

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
                cancelToHome()
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
                cancelToHome()
            }
            .buttonStyle(StickerButtonStyle(background: StickerTheme.blue))
            .padding(.top, 24)
        }
        .onAppear {
            nameFocused = false
            Haptics.warn()
        }
    }

    // MARK: - Leaving

    /// Starts the game with the new friend's deck.
    private func playNow() {
        guard deckReady, let friend = committedFriend else { return }
        Haptics.press()
        nameFocused = false
        friend.name = storedName
        try? modelContext.save()
        appState.roster = [friend]
        appState.screen = .game
    }

    /// Keeps the new friend and goes home; the scan carries on with their album.
    private func saveAndGoHome() {
        guard let friend = committedFriend else { return }
        Haptics.press()
        nameFocused = false
        friend.name = storedName
        try? modelContext.save()
        if !deckReady {
            // Nobody's waiting for the deck any more: stop cutting, but still
            // give them a sticker for the home screen.
            task?.cancel()
            let matches = discoveredMatches
            Task {
                guard friend.stickerData.isEmpty,
                      let image = await Self.pickCoverImage(from: matches, alreadyExtracted: []) else { return }
                Self.applyCover(image, to: friend)
            }
        }
        appState.gameModel.reset()
        appState.roster = []
        appState.usedPhotoIDs = []
        appState.screen = .home
    }

    /// Leaves without saving anything new.
    private func cancelToHome() {
        task?.cancel()
        nameFocused = false
        appState.gameModel.reset()
        appState.pendingPhotoIDs = []
        appState.roster = []
        appState.screen = .home
    }

    /// The X after the friend was saved: deletes them again.
    private func discardFriend() {
        task?.cancel()
        if let friend = committedFriend {
            modelContext.delete(friend)
            try? modelContext.save()
        }
        committedFriend = nil
        cancelToHome()
    }

    // MARK: - Pipeline

    private func start() {
        // Every real round passes through here; the emoji demo never does.
        appState.isDemoRound = false
        let roster = appState.roster
        if roster.isEmpty {
            defaultName = savedFriends.isEmpty ? "Friend" : "Friend \(savedFriends.count + 1)"
        }
        task = Task {
            if roster.isEmpty {
                await runNewFriend()
            } else {
                await runReplay(for: roster)
            }
        }
    }

    /// New friend: find who keeps showing up in the picks, stopping early once
    /// that's clear, save them straight away (leftover picks go to the scan),
    /// then cut out a deck and their cover sticker. Nothing starts the game:
    /// that's the Play button.
    private func runNewFriend() async {
        // Identifying and snipping get the phone to themselves; the scan picks
        // up again (starting with this friend's leftover picks) after.
        let rescanner = appState.rescanner
        rescanner.beginHold()
        defer { rescanner.endHold() }

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

        let needed = appState.cardCount
        let discovery = await service.discoverFriendIdentity(in: assets, earlyCommit: EarlyCommitRule(minPhotos: needed)) { done, total in
            Task { @MainActor in
                if case .identifying = self.phase { self.phase = .identifying(done, total) }
            }
        }
        guard Task.isCancelled == false else { return }

        guard discovery.matches.count >= 4 else {
            phase = .error(
                "Only found the same person in \(discovery.matches.count) of \(assets.count) photos — need at least 4.\n\nTry picking photos where your friend's face is clearly visible."
            )
            return
        }

        // The face is settled: save them now, so leaving from here on loses nothing.
        let friend = Friend(
            name: storedName,
            stickerData: Data(),
            photoMatches: discovery.matches.map { PhotoMatch(assetID: $0.asset.localIdentifier, faceBoundingBox: $0.faceBoundingBox) }
        )
        // What the background scan matches the rest of the library against.
        friend.identity = discovery.identity
        friend.pendingPickedIDs = discovery.unprocessed.map(\.localIdentifier)
        modelContext.insert(friend)
        try? modelContext.save()
        committedFriend = friend
        discoveredMatches = discovery.matches
        appState.pendingPhotoIDs = []
        rescanner.ensureRunning()
        Haptics.done()

        // Solo shots first, so a clean cover candidate is cut out early.
        let sampled = Array(discovery.matches.shuffled().prefix(needed))
            .sorted { $0.isSoloFace && !$1.isSoloFace }
        let soloIDs = Set(sampled.filter(\.isSoloFace).map(\.asset.localIdentifier))
        appState.usedPhotoIDs = Set(sampled.map { $0.asset.localIdentifier })
        cardsToCut = sampled.count

        phase = .extracting(0, sampled.count)
        let extracted = await Self.extractAll(sampled) { done, total, assetID, image in
            Task { @MainActor in
                self.phase = .extracting(done, total)
                guard let image else { return }
                self.previews.append(image)
                Haptics.tick()
                if soloIDs.contains(assetID), let friend = self.committedFriend, friend.stickerData.isEmpty,
                   FaceMatchingService.hasDetectableFace(in: image) {
                    Self.applyCover(image, to: friend)
                    self.coverImage = image
                }
            }
        }
        guard Task.isCancelled == false else { return }

        guard extracted.count >= 4 else {
            phase = .error("Cutting out photos failed for too many of them. Try again.")
            return
        }

        setupGame(from: extracted, friendOf: Dictionary(extracted.map { ($0.assetID, friend.id) }, uniquingKeysWith: { a, _ in a }))
        deckReady = true
        Haptics.done()

        // No solo shot in the deck: pick a cover from everything that matched.
        if friend.stickerData.isEmpty,
           let image = await Self.pickCoverImage(from: discovery.matches, alreadyExtracted: extracted) {
            Self.applyCover(image, to: friend)
            coverImage = image
        }
    }

    /// Saves a cover sticker on a friend, unless they've been discarded meanwhile.
    private static func applyCover(_ image: UIImage, to friend: Friend) {
        guard !friend.isDeleted, let context = friend.modelContext,
              let data = CoverSticker.encode(image) else { return }
        friend.stickerData = data
        try? context.save()
    }

    /// Replay for saved friends — one, or several mixed into one deck. Samples
    /// from albums already known (every face box is stored), shared out by
    /// `DealPlan`, waiting on the scan only if everyone together is short.
    private func runReplay(for roster: [Friend]) async {
        let needed = appState.cardCount
        let rescanner = appState.rescanner
        let rosterIDs = Set(roster.map(\.id))
        func albumTotal() -> Int { roster.reduce(0) { $0 + $1.photoMatches.count } }

        // Not enough photos for a full grid yet: give the scan a chance to find
        // more, focused on whoever is furthest short. Once there are enough the
        // game starts and the scan carries on behind it.
        defer {
            if let id = rescanner.focusFriendID, rosterIDs.contains(id) { rescanner.focusFriendID = nil }
        }
        func focusShortest() {
            let fairShare = (needed + roster.count - 1) / roster.count
            let focus = roster.filter { rescanner.couldStillAdd(to: $0) || !rescanner.isRunning }
                .max { fairShare - $0.photoMatches.count < fairShare - $1.photoMatches.count }
            if rescanner.focusFriendID != focus?.id { rescanner.focusFriendID = focus?.id }
        }
        if albumTotal() < needed {
            focusShortest()
            rescanner.ensureRunning()
        }
        while albumTotal() < needed,
              roster.contains(where: { rescanner.couldStillAdd(to: $0) }),
              !playWithWhatWeHave {
            focusShortest()
            phase = .findingPhotos(albumTotal(), needed)
            try? await Task.sleep(for: .milliseconds(250))
            guard Task.isCancelled == false else { return }
        }
        if let id = rescanner.focusFriendID, rosterIDs.contains(id) { rescanner.focusFriendID = nil }

        // Snipping gets the phone to itself; the scan waits within a photo.
        rescanner.beginHold()
        defer { rescanner.endHold() }

        // Photos not used yet this session; when everyone together is out of
        // those, start over from full albums.
        var unused: [UUID: [PhotoMatch]] = [:]
        for friend in roster {
            unused[friend.id] = friend.photoMatches.filter { !appState.usedPhotoIDs.contains($0.assetID) }
        }
        if Set(unused.values.flatMap { $0.map(\.assetID) }).count < needed {
            for friend in roster { unused[friend.id] = friend.photoMatches }
            appState.usedPhotoIDs = []
        }

        // Share the cards out, never dealing one photo twice (a group shot can
        // be in two of these albums).
        let shares = DealPlan.shares(cardCount: needed, available: unused.mapValues(\.count))
        var taken: Set<String> = []
        var picked: [(match: PhotoMatch, friendID: UUID)] = []
        for friend in roster.shuffled() {
            let want = shares[friend.id] ?? 0
            var got = 0
            for match in (unused[friend.id] ?? []).shuffled() where got < want && !taken.contains(match.assetID) {
                taken.insert(match.assetID)
                picked.append((match, friend.id))
                got += 1
            }
        }
        // Short because of shared photos: top up from anyone with spare.
        if picked.count < needed {
            for friend in roster.shuffled() {
                for match in (unused[friend.id] ?? []).shuffled() where picked.count < needed && !taken.contains(match.assetID) {
                    taken.insert(match.assetID)
                    picked.append((match, friend.id))
                }
            }
        }

        guard picked.count >= 4 else {
            phase = .error(roster.count > 1
                ? "These friends don't have enough photos saved to play."
                : "This friend doesn't have enough photos saved to play.")
            return
        }
        appState.usedPhotoIDs.formUnion(taken)

        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: picked.map(\.match.assetID), options: nil)
        var assetsByID: [String: PHAsset] = [:]
        fetched.enumerateObjects { asset, _, _ in assetsByID[asset.localIdentifier] = asset }

        var friendOf: [String: UUID] = [:]
        let pairs: [FriendPhotoMatch] = picked.compactMap { entry in
            guard let asset = assetsByID[entry.match.assetID] else { return nil }
            friendOf[entry.match.assetID] = entry.friendID
            return FriendPhotoMatch(asset: asset, faceBoundingBox: entry.match.faceBoundingBox, isSoloFace: false)
        }

        guard pairs.count >= 4 else {
            phase = .error("Some of these photos are missing from your library. Try picking new photos.")
            return
        }

        cardsToCut = pairs.count
        phase = .extracting(0, pairs.count)
        let started = Date()
        defer { logger.info("Cut out \(pairs.count) photos for \(roster.count) friend(s) in \(String(format: "%.1f", Date().timeIntervalSince(started)))s") }
        let extracted = await Self.extractAll(pairs) { done, total, _, image in
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

        setupGame(from: extracted, friendOf: friendOf)
        Haptics.done()
        appState.screen = .game
    }

    // MARK: - Game setup

    /// Exactly one angry card, whoever's face it is.
    private func setupGame(from extracted: [(assetID: String, image: UIImage)], friendOf: [String: UUID]) {
        let angryIndex = Int.random(in: 0..<extracted.count)
        let cards = extracted.enumerated().map { i, entry in
            GameCard(image: entry.image, isAngry: i == angryIndex, friendID: friendOf[entry.assetID])
        }
        appState.gameModel.setup(from: cards.shuffled())
    }

    // MARK: - Concurrent extraction

    /// `onProgress` also hands back each finished cutout (and its photo) so the
    /// UI can show the pile growing — it's the same work, just reported as it lands.
    private static func extractAll(
        _ matches: [FriendPhotoMatch],
        onProgress: @escaping @Sendable (Int, Int, String, UIImage?) -> Void
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
                onProgress(results.count, matches.count, assetID, image)
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
        await CoverSticker.cutout(asset: asset, box: box)
    }

    // MARK: - Phase helpers

    private var friendLabel: String {
        let names = appState.roster.map(\.displayName)
        return names.isEmpty ? "your friend" : DealPlan.names(names)
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
        case .extracting: return "cutting \(friendLabel) out of \(cardsToCut) photos"
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
