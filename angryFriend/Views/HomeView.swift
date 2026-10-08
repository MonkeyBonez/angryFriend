import SwiftUI
import PhotosUI
import UIKit
import Photos
import SwiftData

struct HomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(FriendRescanner.enabledKey) private var autoScan = true
    @AppStorage("hasSeenAddFriendTutorial") private var hasSeenTutorial = false
    @State private var tutorial: TutorialMode? = nil
    @Query(sort: \Friend.createdAt, order: .reverse) private var savedFriends: [Friend]

    @State private var showMultiPicker = false
    @State private var permissionDenied = false
    @State private var photoAccess: PHAuthorizationStatus = .notDetermined
    @State private var showAccessAlert = false
    @State private var pickAlert: String? = nil
    @State private var titleLanded = false
    /// "Multiple suspects": tapping a sticker checks it instead of playing.
    @State private var selecting = false
    @State private var selected: Set<UUID> = []

    // 6 = 2x3, 12 = 3x4, 20 = 4x5 — variants to try different grid shapes.
    private let cardCountOptions = [6, 12, 20]

    var body: some View {
        ZStack {
            // The yellow sheet and the confetti dots are drawn once, in ContentView.

            // minHeight pins the stack to at least a full screen so the Spacer
            // actually pushes the footer to the bottom; it still scrolls when a
            // long friend list or the permission note makes the content taller.
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        masthead
                            .padding(.top, 18)

                        Spacer(minLength: 26)

                        if savedFriends.isEmpty {
                            emptyState
                        } else {
                            suspects
                        }

                        if permissionDenied {
                            permissionNote
                                .padding(.top, 22)
                        }

                        Spacer(minLength: 26)

                        footer
                            .padding(.bottom, 14)
                    }
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }

            if let mode = tutorial {
                AddFriendTutorialView(mode: mode) { exit in
                    finishTutorial(mode: mode, exit: exit)
                }
                .zIndex(1)
            }
        }
        .onAppear {
            photoAccess = PhotoLibraryService.shared.authorizationStatus()
            Haptics.warmUp()
            // Covers saved as JPEG lost their transparency; re-cut them once.
            Task { await CoverSticker.repairFlattenedCovers(savedFriends, context: modelContext) }
            appState.rescanner.ensureRunning()
            if let ids = appState.resumeSelection {
                // Back from "change the lineup": same friends, already checked.
                appState.resumeSelection = nil
                selected = Set(ids).intersection(savedFriends.map(\.id))
                selecting = savedFriends.count >= 2 && !selected.isEmpty
            }
            if appState.pendingAddFriend {
                // Sent here from the demo result to add a real friend: let the
                // screen land first, then carry on into the add flow.
                appState.pendingAddFriend = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { requestAndPick() }
            }
            guard !titleLanded else { return }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.55)) { titleLanded = true }
        }
        .sheet(isPresented: $showMultiPicker) {
            MultiImagePicker { assetIdentifiers in
                handlePickedAssets(assetIdentifiers)
            }
        }
        // Coming back from Settings: pick up whatever access was just granted.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                photoAccess = PhotoLibraryService.shared.authorizationStatus()
            }
        }
        .alert("Allow All Photos", isPresented: $showAccessAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("To auto-add new pics of your friends, allow access to all photos in Settings.")
        }
        .alert("Can't Start Game", isPresented: Binding(
            get: { pickAlert != nil },
            set: { if !$0 { pickAlert = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(pickAlert ?? "")
        }
    }

    // MARK: - Sections

    private var masthead: some View {
        VStack(spacing: 2) {
            StickerText(text: "ANGRY", size: 46, fill: .white, strokeWidth: 2.4)
                .rotationEffect(.degrees(-3))
                .offset(y: titleLanded ? 0 : -60)
                .opacity(titleLanded ? 1 : 0)

            StickerText(text: "FRIEND", size: 46, fill: StickerTheme.pink, strokeWidth: 2.4)
                .rotationEffect(.degrees(2))
                .offset(y: titleLanded ? 0 : -90)
                .opacity(titleLanded ? 1 : 0)

            HStack(spacing: 5) {
                Text("one of these cards is")
                    .font(.sticker(13, .semibold))
                    .foregroundStyle(StickerTheme.ink)
                Text("FURIOUS")
                    .font(.sticker(13, .black))
                    .foregroundStyle(StickerTheme.sun)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(StickerTheme.ink, in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(.top, 12)
            .popIn(delay: 0.35, from: 0.7, tilt: 0)
        }
    }

    private var suspects: some View {
        VStack(spacing: 4) {
            sectionLabel(selecting ? "PICK YOUR SUSPECTS · \(selected.count) PICKED" : "YOUR SUSPECTS · TAP TO PLAY")
                .contentTransition(.numericText())

            FriendCarouselView(
                friends: savedFriends,
                onSelect: play,
                onHold: viewAlbum,
                onEdit: editFriend,
                onAddNew: requestAndPick,
                onDemo: playDemo,
                selection: selecting ? FriendSelection(selected: selected, onToggle: toggle) : nil
            )

            if savedFriends.count >= 2 {
                multipleSuspectsRow
                    .padding(.top, 8)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: selecting)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: selected.isEmpty)
    }

    /// The MULTIPLE SUSPECTS toggle (filled while on), with PLAY beside it once
    /// someone's picked.
    private var multipleSuspectsRow: some View {
        HStack(spacing: 10) {
                Button {
                    Haptics.flick()
                    if selecting {
                        resetSelection()
                    } else {
                        selected = []
                        selecting = true
                    }
                } label: {
                    Text("MULTIPLE SUSPECTS")
                }
                .buttonStyle(StickerButtonStyle(background: selecting ? StickerTheme.mint : .white,
                                                foreground: selecting ? .white : StickerTheme.ink,
                                                size: 12, cornerRadius: 999, fullWidth: false))
                .rotationEffect(.degrees(selecting ? 1.5 : -1.5))
                .accessibilityLabel("Multiple suspects")
                .accessibilityValue(selecting ? "On" : "Off")
                .accessibilityHint("Pick several friends to mix into one round")

                if selecting && !selectedFriends.isEmpty {
                    Button("PLAY", action: dealRoster)
                        .buttonStyle(StickerButtonStyle(background: StickerTheme.flame, size: 13, cornerRadius: 999, fullWidth: false))
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
        }
    }

    private var selectedFriends: [Friend] {
        savedFriends.filter { selected.contains($0.id) }
    }

    /// No friends yet: the emoji pal stands in the line-up alone so there's still
    /// a round to play before anyone hands over photos.
    private var emptyState: some View {
        VStack(spacing: 14) {
            Text("No suspects yet")
                .font(.sticker(19, .black))
                .foregroundStyle(StickerTheme.ink)

            EmojiPalSticker(index: 1, size: 96, action: playDemo)
                .padding(.vertical, 8)
                .popIn(delay: 0.4, from: 0.5)

            Text("tap the emoji pal for a practice round")
                .font(.sticker(10.5, .medium))
                .foregroundStyle(StickerTheme.ink.opacity(0.65))
        }
        .popIn(delay: 0.35, from: 0.85, tilt: 0)
    }

    private var permissionNote: some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .bold))
            Text("Photo access is off. Turn it on in Settings.")
                .font(.sticker(12.5, .bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(StickerTheme.flame, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(StickerTheme.ink, lineWidth: 2))
        .hardShadow(StickerTheme.ink, x: 2.5, y: 2.5)
        .rotationEffect(.degrees(-1.5))
        .padding(.horizontal, 28)
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Button(action: requestAndPick) {
                Label(savedFriends.isEmpty ? "Add a Friend's Photos" : "Add Another Friend's Photos",
                      systemImage: "photo.stack.fill")
            }
            .buttonStyle(StickerButtonStyle(background: StickerTheme.pink))
            .padding(.horizontal, 28)
            .popIn(delay: 0.45, from: 0.85, tilt: 0)

            HStack(spacing: 4) {
                Text("tip: your People album in Photos works best ·")
                    .font(.sticker(10.5, .medium))
                    .foregroundStyle(StickerTheme.ink.opacity(0.65))
                Button("how?") {
                    Haptics.press()
                    resetSelection()
                    tutorial = .replay
                }
                .font(.sticker(10.5, .black))
                .underline()
                .foregroundStyle(StickerTheme.ink)
                .accessibilityLabel("How to add a friend")
            }

            cardCountPicker
                .padding(.top, 6)

            autoScanToggle
        }
    }

    /// The switch only reads as on when a scan can actually run — which needs
    /// the whole library, not just the photos picked so far.
    private var autoScanIsOn: Bool {
        autoScan && (photoAccess == .authorized || photoAccess == .notDetermined)
    }

    private var autoScanToggle: some View {
        VStack(spacing: 8) {
            autoScanSwitch
            #if DEBUG
            // What the scan is up to; release builds just do it quietly.
            if autoScanIsOn, let status = appState.rescanner.statusLine {
                Text(status)
                    .font(.sticker(10, .medium))
                    .foregroundStyle(StickerTheme.ink.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.2), value: status)
            }
            #endif
        }
    }

    private var autoScanSwitch: some View {
        HStack(spacing: 8) {
            Text("AUTO-ADD NEW PICS")
                .font(.sticker(10.5, .black))
                .foregroundStyle(StickerTheme.ink.opacity(0.7))
                .padding(.trailing, 2)

            Button(action: toggleAutoScan) {
                Text(autoScanIsOn ? "ON" : "OFF")
                    .font(.sticker(14, .black))
                    .foregroundStyle(autoScanIsOn ? .white : StickerTheme.ink)
                    .frame(width: 58, height: 34)
                    .background(autoScanIsOn ? StickerTheme.mint : Color.white,
                                in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(StickerTheme.ink, lineWidth: 2))
                    .hardShadow(StickerTheme.ink, x: 2, y: 2)
                    .rotationEffect(.degrees(autoScanIsOn ? -2 : 0))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Auto-add new pics of friends")
            .accessibilityValue(autoScanIsOn ? "On" : "Off")
        }
        .popIn(delay: 0.55, from: 0.85, tilt: 0)
    }

    private var cardCountPicker: some View {
        HStack(spacing: 8) {
            Text("GAME SIZE")
                .font(.sticker(10.5, .black))
                .foregroundStyle(StickerTheme.ink.opacity(0.7))
                .padding(.trailing, 2)

            ForEach(cardCountOptions, id: \.self) { count in
                let selected = appState.cardCount == count
                Button {
                    guard !selected else { return }
                    Haptics.flick()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                        appState.cardCount = count
                    }
                } label: {
                    Text("\(count)")
                        .font(.sticker(14, .black))
                        .foregroundStyle(selected ? .white : StickerTheme.ink)
                        .frame(width: 44, height: 34)
                        .background(selected ? StickerTheme.blue : Color.white,
                                    in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(StickerTheme.ink, lineWidth: 2))
                        .hardShadow(StickerTheme.ink, x: 2, y: 2)
                        .scaleEffect(selected ? 1.06 : 1)
                        .rotationEffect(.degrees(selected ? -2 : 0))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(count) cards")
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .popIn(delay: 0.5, from: 0.85, tilt: 0)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.sticker(10.5, .black))
            .foregroundStyle(StickerTheme.ink.opacity(0.7))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 30)
    }

    // MARK: - Actions

    private func toggleAutoScan() {
        Haptics.flick()
        resetSelection()
        if autoScanIsOn {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { autoScan = false }
            appState.rescanner.stop()
            return
        }

        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { autoScan = true }
        switch photoAccess {
        case .authorized:
            appState.rescanner.ensureRunning()
        case .notDetermined:
            Task {
                photoAccess = await PhotoLibraryService.shared.requestAuthorization()
                appState.rescanner.ensureRunning()
            }
        default:
            // iOS only shows its own prompt once — after that, widening access
            // (limited → all photos, or off → on) has to happen in Settings.
            showAccessAlert = true
        }
    }

    private func toggle(_ friend: Friend) {
        if selected.contains(friend.id) {
            selected.remove(friend.id)
        } else {
            selected.insert(friend.id)
        }
    }

    private func resetSelection() {
        guard selecting || !selected.isEmpty else { return }
        selected = []
        selecting = false
    }

    /// Deals the checked friends into one round.
    private func dealRoster() {
        let roster = selectedFriends
        guard !roster.isEmpty else { return }
        Haptics.press()
        appState.roster = roster
        appState.usedPhotoIDs = []
        appState.pendingPhotoIDs = []
        resetSelection()
        appState.rescanner.ensureRunning()
        appState.screen = .processing
    }

    private func playDemo() {
        resetSelection()
        appState.startDemoRound()
    }

    private func play(_ friend: Friend) {
        resetSelection()
        appState.roster = [friend]
        appState.usedPhotoIDs = []
        appState.rescanner.ensureRunning()
        appState.screen = .processing
    }

    private func viewAlbum(_ friend: Friend) {
        resetSelection()
        appState.viewingFriend = friend
        appState.screen = .album
    }

    private func editFriend(_ friend: Friend) {
        resetSelection()
        appState.viewingFriend = friend
        appState.screen = .friendDetail
    }

    /// First time through, the tutorial comes before the system photo prompt so
    /// its last frame can explain what "all photos" is for before iOS asks.
    private func requestAndPick() {
        resetSelection()
        if hasSeenTutorial {
            requestAccessThenPick()
        } else {
            tutorial = .firstRun
        }
    }

    private func requestAccessThenPick() {
        Task {
            let status = await PhotoLibraryService.shared.requestAuthorization()
            photoAccess = status
            if status == .authorized || status == .limited {
                permissionDenied = false
                showMultiPicker = true
            } else {
                Haptics.warn()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                    permissionDenied = true
                }
            }
        }
    }

    /// "Got it" always lands in the picker. Skipping the first-run card does too —
    /// they tapped add-friend, so that's where they were headed.
    private func finishTutorial(mode: TutorialMode, exit: TutorialExit) {
        hasSeenTutorial = true
        tutorial = nil
        if exit == .gotIt || mode == .firstRun {
            requestAccessThenPick()
        }
    }

    private func handlePickedAssets(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }

        guard identifiers.count >= appState.cardCount else {
            Haptics.warn()
            pickAlert = "You picked \(identifiers.count) photo\(identifiers.count == 1 ? "" : "s") — pick at least \(appState.cardCount) photos of your friend."
            return
        }

        resetSelection()
        appState.roster = []
        appState.pendingPhotoIDs = identifiers
        appState.usedPhotoIDs = []
        appState.screen = .processing
    }
}

// MARK: - PHPicker wrapper (multi selection, returns asset identifiers)

/// The user can navigate to Albums → People & Pets inside the picker themselves — Apple's
/// face clusters have no public API, so this out-of-process picker is the only way to
/// leverage them. photoLibrary-based config is required for non-nil assetIdentifiers.
struct MultiImagePicker: UIViewControllerRepresentable {
    let completion: @MainActor ([String]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        // Explicitly excluding videos as well: `.images` alone has let videos show
        // up inside People collections. Screenshots are never a friend's face.
        config.filter = .all(of: [.images, .not(.videos), .not(.screenshots)])
        config.selectionLimit = 0
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    @MainActor
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let completion: @MainActor ([String]) -> Void
        init(completion: @escaping @MainActor ([String]) -> Void) { self.completion = completion }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            let identifiers = results.compactMap(\.assetIdentifier)
            guard !identifiers.isEmpty else { return }

            // Belt-and-suspenders: config.filter = .images already asks the picker to
            // exclude videos, but re-check media type here too — some albums (e.g. a
            // shared/synced album) have shown videos slipping past the picker filter.
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
            var imageIDs: Set<String> = []
            fetched.enumerateObjects { asset, _, _ in
                if asset.mediaType == .image { imageIDs.insert(asset.localIdentifier) }
            }
            let filtered = identifiers.filter { imageIDs.contains($0) }
            guard !filtered.isEmpty else { return }
            completion(filtered)
        }
    }
}
