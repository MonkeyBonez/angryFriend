import SwiftUI
import UIKit
import Photos
import SwiftData

struct FriendAlbumView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let friend = appState.viewingFriend {
            FriendAlbumContent(friend: friend)
        } else {
            Color.clear.onAppear { appState.screen = .home }
        }
    }
}

private struct FriendAlbumContent: View {
    let friend: Friend
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext

    @State private var assets: [PHAsset] = []

    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var showDeleteConfirm = false

    @State private var showAddPicker = false
    @State private var isProcessingAdd = false
    @State private var addStatusMessage: String? = nil

    @State private var isSettingCover = false
    @State private var coverStatusMessage: String? = nil

    private let columns = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
    ]

    var body: some View {
        ZStack {
            StickerTheme.sun.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar

                if appState.isPickingCoverPhoto {
                    TapeLabel(text: "TAP A PHOTO TO MAKE IT THE COVER",
                              tilt: -1.5, size: 11.5,
                              background: StickerTheme.pink, foreground: .white)
                        .padding(.bottom, 8)
                } else if isSelecting {
                    TapeLabel(text: selectedIDs.isEmpty
                                ? "TAP PHOTOS TO REMOVE THEM"
                                : "\(selectedIDs.count) SELECTED",
                              tilt: 1.5, size: 11.5,
                              background: StickerTheme.blue, foreground: .white)
                        .padding(.bottom, 8)
                }

                ScrollView {
                    if assets.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(Array(assets.enumerated()), id: \.element.localIdentifier) { index, asset in
                                AlbumPhotoCell(
                                    asset: asset,
                                    index: index,
                                    isSelecting: isSelecting,
                                    isSelected: selectedIDs.contains(asset.localIdentifier)
                                ) {
                                    handleTap(asset)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
            }
        }
        .onAppear { Haptics.warmUp() }
        .task { loadAssets() }
        .sheet(isPresented: $showAddPicker) {
            MultiImagePicker { identifiers in
                addPhotos(identifiers)
            }
        }
        .confirmationDialog(
            "Remove \(selectedIDs.count) photo\(selectedIDs.count == 1 ? "" : "s")?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive, action: removeSelected)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This only removes them from the game — they stay in your photo library.")
        }
        .alert("Add Photos", isPresented: Binding(
            get: { addStatusMessage != nil },
            set: { if !$0 { addStatusMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(addStatusMessage ?? "")
        }
        .alert("Cover Photo", isPresented: Binding(
            get: { coverStatusMessage != nil },
            set: { if !$0 { coverStatusMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(coverStatusMessage ?? "")
        }
        .overlay { if isProcessingAdd || isSettingCover { busyOverlay } }
    }

    // MARK: - Chrome

    private var topBar: some View {
        StickerTopBar(
            title: appState.isPickingCoverPhoto ? "Pick a Cover" : "\(displayName)'s Album",
            leadingLabel: appState.isPickingCoverPhoto || isSelecting ? "Cancel" : "Done",
            onLeading: handleLeading
        ) {
            if !appState.isPickingCoverPhoto {
                HStack(spacing: 8) {
                    if isSelecting {
                        Button {
                            Haptics.warn()
                            showDeleteConfirm = true
                        } label: {
                            Image(systemName: "trash.fill")
                        }
                        .buttonStyle(StickerCircleButtonStyle(
                            diameter: 32,
                            background: selectedIDs.isEmpty ? Color.white.opacity(0.5) : StickerTheme.flame,
                            foreground: selectedIDs.isEmpty ? StickerTheme.ink.opacity(0.4) : .white
                        ))
                        .disabled(selectedIDs.isEmpty)
                        .accessibilityLabel("Remove selected photos")
                    } else {
                        Button {
                            Haptics.press()
                            showAddPicker = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(StickerCircleButtonStyle(diameter: 32, background: StickerTheme.mint, foreground: .white))
                        .accessibilityLabel("Add photos")

                        Button {
                            Haptics.press()
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { isSelecting = true }
                        } label: {
                            Image(systemName: "checkmark.circle")
                        }
                        .buttonStyle(StickerCircleButtonStyle(diameter: 32))
                        .disabled(assets.isEmpty)
                        .opacity(assets.isEmpty ? 0.45 : 1)
                        .accessibilityLabel("Select photos")
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 42, weight: .bold))
                .foregroundStyle(StickerTheme.ink.opacity(0.35))
            Text("No photos yet")
                .font(.sticker(15, .black))
                .foregroundStyle(StickerTheme.ink.opacity(0.6))
        }
        .padding(.top, 90)
    }

    private var busyOverlay: some View {
        ZStack {
            StickerTheme.ink.opacity(0.4).ignoresSafeArea()

            VStack(spacing: 14) {
                Image(systemName: isSettingCover ? "wand.and.stars" : "sparkle.magnifyingglass")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(StickerTheme.pink)
                    .wiggling(true, amount: 7, speed: 0.7)

                Text(isSettingCover ? "Setting cover…" : "Checking new photos…")
                    .font(.sticker(14, .heavy))
                    .foregroundStyle(StickerTheme.ink)
            }
            .padding(26)
            .stickerCard(cornerRadius: 18)
        }
        .transition(.opacity)
    }

    private var displayName: String {
        friend.name.isEmpty ? "Friend" : friend.name
    }

    // MARK: - Actions

    private func handleLeading() {
        if appState.isPickingCoverPhoto {
            appState.isPickingCoverPhoto = false
            appState.screen = .friendDetail
        } else if isSelecting {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                isSelecting = false
                selectedIDs = []
            }
        } else {
            appState.viewingFriend = nil
            appState.screen = .home
        }
    }

    private func loadAssets() {
        let ids = friend.photoMatches.map(\.assetID)
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var result: [PHAsset] = []
        fetched.enumerateObjects { asset, _, _ in result.append(asset) }
        assets = result.sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
    }

    private func handleTap(_ asset: PHAsset) {
        if appState.isPickingCoverPhoto {
            Haptics.press()
            setCover(asset)
        } else if isSelecting {
            Haptics.peel()
            withAnimation(.spring(response: 0.25, dampingFraction: 0.65)) {
                toggleSelection(asset.localIdentifier)
            }
        }
    }

    private func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    // MARK: - Re-pick cover photo

    /// The album only stores photos already confirmed to be this friend (from
    /// creation or `addPhotos`), so the face box is already known — just extract
    /// and verify a face is still detectable in the cutout before committing it.
    private func setCover(_ asset: PHAsset) {
        guard let match = friend.photoMatches.first(where: { $0.assetID == asset.localIdentifier }) else { return }
        isSettingCover = true
        Task {
            defer { isSettingCover = false }

            guard let cutout = await CoverSticker.cutout(asset: asset, box: match.faceBoundingBox) else {
                Haptics.warn()
                coverStatusMessage = "Couldn't load that photo."
                return
            }

            guard FaceMatchingService.hasDetectableFace(in: cutout) else {
                Haptics.warn()
                coverStatusMessage = "Couldn't clearly detect a face in that cutout — try a different photo."
                return
            }

            friend.stickerData = CoverSticker.encode(cutout) ?? friend.stickerData
            try? modelContext.save()
            Haptics.done()
            appState.isPickingCoverPhoto = false
            appState.screen = .friendDetail
        }
    }

    // MARK: - Remove

    private func removeSelected() {
        friend.photoMatches.removeAll { selectedIDs.contains($0.assetID) }
        // Removed on purpose: the rescan must not quietly put these back.
        friend.excludedIDs.append(contentsOf: selectedIDs.filter { !friend.excludedIDs.contains($0) })
        try? modelContext.save()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            assets.removeAll { selectedIDs.contains($0.localIdentifier) }
            selectedIDs = []
            isSelecting = false
        }
        Haptics.done()
    }

    // MARK: - Add (deduped, identity-checked)

    private func addPhotos(_ identifiers: [String]) {
        // Picking a photo back by hand lifts its exclusion.
        friend.excludedIDs.removeAll { identifiers.contains($0) }
        let existingIDs = Set(friend.photoMatches.map(\.assetID))
        let newIDs = identifiers.filter { !existingIDs.contains($0) }

        guard !newIDs.isEmpty else {
            Haptics.warn()
            addStatusMessage = "Those photos are already in the album."
            return
        }

        isProcessingAdd = true
        Task {
            defer { isProcessingAdd = false }

            let newFetch = PHAsset.fetchAssets(withLocalIdentifiers: newIDs, options: nil)
            var newAssets: [PHAsset] = []
            newFetch.enumerateObjects { asset, _, _ in newAssets.append(asset) }
            guard !newAssets.isEmpty else {
                Haptics.warn()
                addStatusMessage = "Couldn't load those photos."
                return
            }

            // Anchor with a sample of already-confirmed photos of this friend so
            // identity discovery has something reliable to match the new ones against.
            let anchorIDs = Array(existingIDs.shuffled().prefix(8))
            let anchorFetch = PHAsset.fetchAssets(withLocalIdentifiers: anchorIDs, options: nil)
            var anchorAssets: [PHAsset] = []
            anchorFetch.enumerateObjects { asset, _, _ in anchorAssets.append(asset) }

            guard let service = try? FaceMatchingService() else {
                Haptics.warn()
                addStatusMessage = "Couldn't load the face model."
                return
            }

            let discovery = await service.discoverFriendIdentity(in: anchorAssets + newAssets)
            let newIDSet = Set(newAssets.map(\.localIdentifier))
            let found = discovery.matches.filter { newIDSet.contains($0.asset.localIdentifier) }

            guard !found.isEmpty else {
                Haptics.warn()
                addStatusMessage = "Couldn't find \(displayName) in \(newAssets.count == 1 ? "that photo" : "those photos")."
                return
            }

            friend.photoMatches.append(contentsOf: found.map {
                PhotoMatch(assetID: $0.asset.localIdentifier, faceBoundingBox: $0.faceBoundingBox)
            })
            try? modelContext.save()
            loadAssets()
            Haptics.done()

            let skipped = newAssets.count - found.count
            if skipped > 0 {
                addStatusMessage = "Added \(found.count) photo\(found.count == 1 ? "" : "s"). Didn't find \(displayName) in \(skipped) other\(skipped == 1 ? "" : "s")."
            }
        }
    }
}

private struct AlbumPhotoCell: View {
    let asset: PHAsset
    var index: Int = 0
    var isSelecting: Bool = false
    var isSelected: Bool = false
    var onTap: () -> Void = {}

    @State private var image: UIImage?

    var body: some View {
        // GeometryReader pins down the exact square side length the grid column gave
        // this cell. Without it, a wide (landscape) source photo's scaledToFill can
        // render larger than the cell before clipping catches up, spilling into and
        // overlapping neighboring cells.
        GeometryReader { geo in
            let side = geo.size.width

            ZStack(alignment: .topTrailing) {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: side, height: side)
                        .clipped()
                } else {
                    StickerTheme.tile(index).opacity(0.6)
                }

                if isSelecting {
                    Image(systemName: isSelected ? "checkmark" : "circle")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(isSelected ? .white : .white.opacity(0.9))
                        .frame(width: 24, height: 24)
                        .background(isSelected ? StickerTheme.flame : StickerTheme.ink.opacity(0.35), in: Circle())
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .padding(6)
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? StickerTheme.flame : StickerTheme.ink,
                            lineWidth: isSelected ? 3.5 : 2)
            )
            .hardShadow(StickerTheme.ink.opacity(0.3), x: 2, y: 2)
            .scaleEffect(isSelected ? 0.93 : 1)
            .contentShape(Rectangle())
            .onTapGesture { onTap() }
        }
        .aspectRatio(1, contentMode: .fit)
        .task {
            image = await PhotoLibraryService.shared.loadImage(
                for: asset,
                targetSize: CGSize(width: 300, height: 300)
            )
        }
    }
}
