import SwiftUI
import PhotosUI
import UIKit
import Photos
import SwiftData

struct HomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Friend.createdAt, order: .reverse) private var savedFriends: [Friend]

    @State private var showMultiPicker = false
    @State private var permissionDenied = false
    @State private var pickAlert: String? = nil
    @State private var titleLanded = false

    // 6 = 2x3, 12 = 3x4, 20 = 4x5 — variants to try different grid shapes.
    private let cardCountOptions = [6, 12, 20]

    var body: some View {
        ZStack {
            StickerTheme.sun.ignoresSafeArea()
            ConfettiSheet(count: 30, seed: 11).ignoresSafeArea()

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
        }
        .onAppear {
            Haptics.warmUp()
            guard !titleLanded else { return }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.55)) { titleLanded = true }
        }
        .sheet(isPresented: $showMultiPicker) {
            MultiImagePicker { assetIdentifiers in
                handlePickedAssets(assetIdentifiers)
            }
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
            sectionLabel("YOUR SUSPECTS · TAP TO PLAY")

            FriendCarouselView(
                friends: savedFriends,
                onSelect: play,
                onHold: viewAlbum,
                onEdit: editFriend,
                onAddNew: requestAndPick
            )

            Text("hold a sticker to peek at their album")
                .font(.sticker(10.5, .medium))
                .foregroundStyle(StickerTheme.ink.opacity(0.65))
                .padding(.top, 2)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            ZStack {
                // Side cards first so the middle one — the one holding the icon —
                // sits on top of the fan.
                blankCard(tile: 0).rotationEffect(.degrees(-10)).offset(x: -44)
                blankCard(tile: 2).rotationEffect(.degrees(10)).offset(x: 44)
                blankCard(tile: 1)
                    .overlay {
                        Image(systemName: "person.fill.questionmark")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundStyle(StickerTheme.ink)
                    }
            }
            .popIn(delay: 0.4, from: 0.5)

            Text("No suspects yet")
                .font(.sticker(19, .black))
                .foregroundStyle(StickerTheme.ink)

            Text("Pick a handful of photos of one friend.\nWe'll find them and cut them into cards.")
                .font(.sticker(13, .medium))
                .foregroundStyle(StickerTheme.ink.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
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
                Label(savedFriends.isEmpty ? "Pick Photos of a Friend" : "Add Another Friend",
                      systemImage: "photo.stack.fill")
            }
            .buttonStyle(StickerButtonStyle(background: StickerTheme.pink))
            .padding(.horizontal, 28)
            .popIn(delay: 0.45, from: 0.85, tilt: 0)

            Text("tip: your People album in Photos works best")
                .font(.sticker(10.5, .medium))
                .foregroundStyle(StickerTheme.ink.opacity(0.65))

            cardCountPicker
                .padding(.top, 6)
        }
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

    private func blankCard(tile: Int) -> some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(StickerTheme.tile(tile))
            .frame(width: 78, height: 78)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(StickerTheme.ink, lineWidth: 2.5))
            .hardShadow(StickerTheme.ink.opacity(0.3), x: 3, y: 3)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.sticker(10.5, .black))
            .foregroundStyle(StickerTheme.ink.opacity(0.7))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 30)
    }

    // MARK: - Actions

    private func play(_ friend: Friend) {
        appState.currentFriend = friend
        appState.usedPhotoIDs = []
        appState.screen = .processing
    }

    private func viewAlbum(_ friend: Friend) {
        appState.viewingFriend = friend
        appState.screen = .album
    }

    private func editFriend(_ friend: Friend) {
        appState.viewingFriend = friend
        appState.screen = .friendDetail
    }

    private func requestAndPick() {
        Task {
            let status = await PhotoLibraryService.shared.requestAuthorization()
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

    private func handlePickedAssets(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }

        guard identifiers.count >= appState.cardCount else {
            Haptics.warn()
            pickAlert = "You picked \(identifiers.count) photo\(identifiers.count == 1 ? "" : "s") — pick at least \(appState.cardCount) photos of your friend."
            return
        }

        appState.currentFriend = nil
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
        config.filter = .images
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
