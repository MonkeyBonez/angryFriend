import SwiftUI
import UIKit
import Photos
import SwiftData

// MARK: - App-level state

@Observable
@MainActor
final class AppState {
    var screen: AppScreen = .seedPicker
    var seedImages: [UIImage] = []
    var gameModel = GameModel()
    var cardCount: Int = 9
    var matchPool: [MatchedAsset] = []      // persists across rounds for current friend session
    var usedAssetIDs: Set<String> = []     // tracks which pool photos have been used
    var useZoomMode: Bool = false
    var currentFriend: Friend? = nil       // set when loading a saved friend
}

enum AppScreen {
    case seedPicker
    case scanning
    case game
    case result
    case debug
}

// MARK: - Root view

struct ContentView: View {
    @State private var appState = AppState()
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch appState.screen {
            case .seedPicker:
                SeedPickerView()
            case .scanning:
                ScanningView()
            case .game:
                GameView()
            case .result:
                ResultView()
            case .debug:
                DebugScanView()
            }
        }
        .environment(appState)
        .animation(.easeInOut(duration: 0.35), value: appState.screen == .seedPicker)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                runBackgroundScanForSavedFriends()
            }
        }
    }

    // MARK: Feature 5: Background incremental scan on app open

    private struct FriendScanSnapshot: Sendable {
        let friendID: UUID
        let seedImageData: [Data]
        let matchedAssetIDs: [String]
        let lastScannedAt: Date
    }

    private func runBackgroundScanForSavedFriends() {
        let friends: [Friend]
        do {
            friends = try modelContext.fetch(FetchDescriptor<Friend>())
        } catch { return }
        guard !friends.isEmpty else { return }

        // Extract Sendable snapshot before crossing actor boundary
        let snapshots = friends.map {
            FriendScanSnapshot(
                friendID: $0.id,
                seedImageData: $0.seedImageData,
                matchedAssetIDs: $0.matchedAssetIDs,
                lastScannedAt: $0.lastScannedAt
            )
        }

        Task.detached(priority: .background) {
            for snapshot in snapshots {
                guard !Task.isCancelled else { return }
                let newAssets = await PhotoLibraryService.shared.fetchAssets(since: snapshot.lastScannedAt)
                guard !newAssets.isEmpty else { continue }

                let seedImages = snapshot.seedImageData.compactMap { UIImage(data: $0) }
                guard !seedImages.isEmpty else { continue }

                let service: FaceMatchingService
                do { service = try FaceMatchingService() } catch { continue }

                let embeddings: [FaceEmbedding]
                do { embeddings = try await service.extractSeedEmbeddings(from: seedImages) } catch { continue }

                let newMatches = (try? await service.scanCameraRoll(
                    seedEmbeddings: embeddings,
                    assets: newAssets,
                    matchCap: nil,
                    onProgress: { _ in },
                    onMatch: nil
                )) ?? []

                let newIDs = newMatches.map { $0.asset.localIdentifier }
                let existingSet = Set(snapshot.matchedAssetIDs)
                let dedupedNew = newIDs.filter { !existingSet.contains($0) }
                guard !dedupedNew.isEmpty else { continue }

                let fid = snapshot.friendID
                await MainActor.run { [dedupedNew] in
                    let descriptor = FetchDescriptor<Friend>(predicate: #Predicate { $0.id == fid })
                    if let friend = try? self.modelContext.fetch(descriptor).first {
                        friend.matchedAssetIDs.append(contentsOf: dedupedNew)
                        friend.lastScannedAt = Date()
                        try? self.modelContext.save()
                    }
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
