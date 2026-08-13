import SwiftUI
import PhotosUI
import UIKit
import SwiftData

struct SeedPickerView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Friend.lastScannedAt, order: .reverse) private var savedFriends: [Friend]

    @State private var showPicker = false
    @State private var showMultiPicker = false
    @State private var permissionDenied = false
    @State private var pendingFaceCrops: [(crop: UIImage, normalizedBox: CGRect)] = []
    @State private var showFacePicker = false
    @State private var showNoFaceAlert = false
    @State private var manualPickAlert: String? = nil

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color(.systemBackground).ignoresSafeArea()

            // Debug button
            Button {
                appState.screen = .debug
            } label: {
                Image(systemName: "ladybug")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .padding(16)
            }
            .zIndex(1)

            VStack(spacing: 32) {
                Spacer()

                VStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 72))
                        .foregroundStyle(.orange)

                    Text("Angry Friend")
                        .font(.largeTitle.bold())

                    Text("Pick a photo of your friend to find them in your camera roll.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                if !savedFriends.isEmpty {
                    FriendCarouselView(
                        friends: savedFriends,
                        onSelect: loadSavedFriend,
                        onAddNew: { clearSession() }
                    )
                }

                // Single seed thumbnail
                if let seedImage = appState.seedImages.first {
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: seedImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 140, height: 140)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .shadow(radius: 6)

                        Button {
                            appState.seedImages = []
                            clearPool()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .offset(x: 8, y: -8)
                    }
                }

                if permissionDenied {
                    Label("Photo access denied. Enable it in Settings.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                VStack(spacing: 16) {
                    Button(action: requestAndPick) {
                        Label(
                            appState.seedImages.isEmpty ? "Choose Photo" : "Change Photo",
                            systemImage: "photo.on.rectangle"
                        )
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.orange)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .padding(.horizontal, 32)

                    VStack(spacing: 4) {
                        Button(action: requestAndPickManual) {
                            Label("Pick Photos Yourself", systemImage: "person.2.crop.square.stack")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color(.secondarySystemFill))
                                .foregroundStyle(.primary)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }

                        Text("Choose from your People album in Photos — no scanning needed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 32)

                    HStack {
                        Text("Cards in game")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Picker("Cards", selection: Binding(
                            get: { appState.cardCount },
                            set: { appState.cardCount = $0 }
                        )) {
                            Text("9").tag(9)
                            Text("12").tag(12)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 160)
                    }
                    .padding(.horizontal, 32)

                    if !appState.seedImages.isEmpty {
                        Button(action: { appState.screen = .scanning }) {
                            Text("Scan Camera Roll")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(.blue)
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .padding(.horizontal, 32)
                    }
                }

                Spacer()
            }
        }
        .sheet(isPresented: $showPicker) {
            ImagePicker { image in
                handlePickedImage(image)
            }
        }
        .sheet(isPresented: $showMultiPicker) {
            MultiImagePicker { assetIdentifiers in
                handlePickedAssets(assetIdentifiers)
            }
        }
        .alert("Can't Start Game", isPresented: Binding(
            get: { manualPickAlert != nil },
            set: { if !$0 { manualPickAlert = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(manualPickAlert ?? "")
        }
        .sheet(isPresented: $showFacePicker) {
            FacePickerView(
                crops: pendingFaceCrops,
                onSelect: { selectedCrop in
                    appState.seedImages = [selectedCrop]
                    clearPool()
                    showFacePicker = false
                },
                onSkip: {
                    showFacePicker = false
                }
            )
        }
        .alert("No Face Detected", isPresented: $showNoFaceAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("No face was detected in that photo. Try a clearer front-facing photo.")
        }
    }

    // MARK: - Image handling

    private func handlePickedImage(_ image: UIImage) {
        Task {
            let crops = await FaceMatchingService.detectFaceCrops(in: image)
            if crops.isEmpty {
                showNoFaceAlert = true
            } else if crops.count == 1 {
                appState.seedImages = [crops[0].crop]
                clearPool()
            } else {
                pendingFaceCrops = crops
                showFacePicker = true
            }
        }
    }

    // MARK: - Load saved friend

    private func loadSavedFriend(_ friend: Friend) {
        appState.seedImages = friend.seedImageData.compactMap { UIImage(data: $0) }
        appState.currentFriend = friend

        let assets = PHAsset.fetchAssets(
            withLocalIdentifiers: friend.matchedAssetIDs,
            options: nil
        )
        var pool: [MatchedAsset] = []
        assets.enumerateObjects { asset, _, _ in
            pool.append(MatchedAsset(asset: asset, similarity: 1.0, faceBoundingBox: .zero))
        }
        appState.matchPool = pool.shuffled()
        appState.usedAssetIDs = []
        appState.screen = .scanning
    }

    // MARK: - Helpers

    private func clearPool() {
        appState.matchPool = []
        appState.usedAssetIDs = []
        appState.currentFriend = nil
    }

    private func clearSession() {
        appState.seedImages = []
        clearPool()
    }

    private func requestAndPick() {
        Task {
            let status = await PhotoLibraryService.shared.requestAuthorization()
            if status == .authorized || status == .limited {
                permissionDenied = false
                showPicker = true
            } else {
                permissionDenied = true
            }
        }
    }

    private func requestAndPickManual() {
        Task {
            let status = await PhotoLibraryService.shared.requestAuthorization()
            if status == .authorized || status == .limited {
                permissionDenied = false
                showMultiPicker = true
            } else {
                permissionDenied = true
            }
        }
    }

    // MARK: - Manual pick (People album alternative to scanning)

    private func handlePickedAssets(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }

        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var pool: [MatchedAsset] = []
        fetched.enumerateObjects { asset, _, _ in
            pool.append(MatchedAsset(asset: asset, similarity: 1.0, faceBoundingBox: .zero))
        }

        guard pool.count >= appState.cardCount else {
            if pool.count < identifiers.count {
                manualPickAlert = "Only \(pool.count) of \(identifiers.count) photos could be loaded — allow full photo access in Settings, then try again."
            } else {
                manualPickAlert = "You picked \(pool.count) photo\(pool.count == 1 ? "" : "s") — pick at least \(appState.cardCount) photos of your friend."
            }
            return
        }

        appState.seedImages = []
        appState.currentFriend = nil
        appState.matchPool = pool.shuffled()
        appState.usedAssetIDs = []
        appState.screen = .scanning
    }
}

// MARK: - PHPicker wrapper (single selection)

struct ImagePicker: UIViewControllerRepresentable {
    let completion: @MainActor (UIImage) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    @MainActor
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let completion: @MainActor (UIImage) -> Void
        init(completion: @escaping @MainActor (UIImage) -> Void) { self.completion = completion }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let result = results.first else { return }

            result.itemProvider.loadObject(ofClass: UIImage.self) { obj, _ in
                if let image = obj as? UIImage {
                    DispatchQueue.main.async { [weak self] in
                        self?.completion(image)
                    }
                }
            }
        }
    }
}

// MARK: - PHPicker wrapper (multi selection, returns asset identifiers)

/// The user navigates to Albums → People & Pets inside the picker themselves — Apple's
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
            completion(identifiers)
        }
    }
}
