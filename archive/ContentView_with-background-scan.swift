import SwiftUI
import UIKit
import Photos
import SwiftData

// TEMP: Set to true to re-enable iCloud photo scanning in background passes.
private let iCloudScanEnabled = false

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
    var currentFriend: Friend? = nil       // set when loading a saved friend

    // Background scan state
    var iCloudScanToast: ICloudScanToast? = nil
    var isICloudScanning: Bool = false
    // Single-owner slot — every scan path cancels the previous one before storing itself.
    var backgroundScanTask: Task<Void, Never>? = nil
}

struct ICloudScanToast {
    var friendName: String
    var scanned: Int
    var total: Int
    var isComplete: Bool = false
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
        ZStack(alignment: .bottom) {
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

            if let toast = appState.iCloudScanToast {
                ICloudScanToastView(toast: toast)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.35), value: appState.screen == .seedPicker)
        .animation(.spring(duration: 0.4), value: appState.iCloudScanToast != nil)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                runBackgroundScanForSavedFriends()
            }
        }
    }

    // MARK: - Background scan on app open

    private struct FriendScanSnapshot: Sendable {
        let friendID: UUID
        let friendName: String
        let seedImageData: [Data]
        let matchedAssetIDs: [String]
        let lastScannedAt: Date
        let localScanCompleted: Bool
        let localLastScannedDate: Date?
        let iCloudPassCompleted: Bool
        let iCloudLastScannedDate: Date?
    }

    private func runBackgroundScanForSavedFriends() {
        // Don't run while ScanningView is active (it handles its own scans)
        guard appState.screen != .scanning else { return }
        guard !appState.isICloudScanning else { return }

        let friends: [Friend]
        do {
            friends = try modelContext.fetch(FetchDescriptor<Friend>())
        } catch { return }
        guard !friends.isEmpty else { return }

        let snapshots = friends.map {
            FriendScanSnapshot(
                friendID: $0.id,
                friendName: $0.name,
                seedImageData: $0.seedImageData,
                matchedAssetIDs: $0.matchedAssetIDs,
                lastScannedAt: $0.lastScannedAt,
                localScanCompleted: $0.localScanCompleted,
                localLastScannedDate: $0.localLastScannedDate,
                iCloudPassCompleted: $0.iCloudPassCompleted,
                iCloudLastScannedDate: $0.iCloudLastScannedDate
            )
        }

        let state = appState

        // Cancel any prior background scan and claim the single-owner slot.
        appState.backgroundScanTask?.cancel()
        let newTask = Task.detached(priority: .background) {
            for snapshot in snapshots {
                guard !Task.isCancelled else { return }

                let seedImages = snapshot.seedImageData.compactMap { UIImage(data: $0) }
                guard !seedImages.isEmpty else { continue }

                // Claim the scanning flag before doing ANY network work for this friend.
                let alreadyBusy = await MainActor.run { () -> Bool in
                    if state.isICloudScanning { return true }
                    state.isICloudScanning = true
                    state.iCloudScanToast = ICloudScanToast(friendName: snapshot.friendName, scanned: 0, total: 0)
                    return false
                }
                guard !alreadyBusy else { return }

                // Ensure the flag is always cleared when we leave this friend's block.
                defer {
                    Task { @MainActor in
                        state.isICloudScanning = false
                        state.iCloudScanToast = nil
                    }
                }

                let service: FaceMatchingService
                do { service = try FaceMatchingService() } catch { continue }

                let embeddings: [FaceEmbedding]
                do { embeddings = try await service.extractSeedEmbeddings(from: seedImages) } catch { continue }

                let existingSet = Set(snapshot.matchedAssetIDs)
                let fid = snapshot.friendID
                let name = snapshot.friendName

                // A: Scan new local photos since last scan date (fast, small set)
                guard !Task.isCancelled else { return }
                let newAssets = await PhotoLibraryService.shared.fetchAssets(since: snapshot.lastScannedAt)
                if !newAssets.isEmpty {
                    let result = try? await service.scanCameraRoll(
                        seedEmbeddings: embeddings,
                        assets: newAssets,
                        matchCap: nil,
                        onProgress: { _ in },
                        onMatch: nil
                    )
                    let newIDs = (result?.matches ?? []).map { $0.asset.localIdentifier }
                    let dedupedNew = newIDs.filter { !existingSet.contains($0) }
                    if !dedupedNew.isEmpty {
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

                // B: Resume incomplete local or iCloud pass — date-based filtering
                let needsLocal = !snapshot.localScanCompleted
                let needsICloud = !snapshot.iCloudPassCompleted
                guard (needsLocal || needsICloud) && !Task.isCancelled else { continue }

                let allAssets = await PhotoLibraryService.shared.fetchAllCameraRollAssets()
                guard !allAssets.isEmpty else { continue }

                // B1: Resume local scan if not complete
                if needsLocal && !Task.isCancelled {
                    let localAssets: [PHAsset]
                    if let d = snapshot.localLastScannedDate {
                        localAssets = allAssets.filter { ($0.creationDate ?? .distantPast) < d }
                    } else {
                        localAssets = allAssets
                    }
                    if !localAssets.isEmpty {
                        await MainActor.run {
                            state.iCloudScanToast = ICloudScanToast(
                                friendName: name, scanned: 0, total: localAssets.count
                            )
                        }
                        let localResult = try? await service.scanCameraRoll(
                            seedEmbeddings: embeddings,
                            assets: localAssets,
                            matchCap: nil,
                            allowNetwork: false,
                            onProgress: { progress in
                                Task { @MainActor in
                                    state.iCloudScanToast = ICloudScanToast(
                                        friendName: name, scanned: progress.scanned, total: progress.total
                                    )
                                    if progress.scanned % 50 == 0, progress.scanned > 0,
                                       progress.scanned <= localAssets.count {
                                        let asset = localAssets[progress.scanned - 1]
                                        let d2 = FetchDescriptor<Friend>(predicate: #Predicate { $0.id == fid })
                                        if let f = try? self.modelContext.fetch(d2).first {
                                            f.localLastScannedDate = asset.creationDate
                                            try? self.modelContext.save()
                                        }
                                    }
                                }
                            },
                            onMatch: nil
                        )
                        let localIDs = (localResult?.matches ?? []).map { $0.asset.localIdentifier }
                        let dedupedLocal = localIDs.filter { !existingSet.contains($0) }
                        if !dedupedLocal.isEmpty {
                            await MainActor.run { [dedupedLocal] in
                                let d2 = FetchDescriptor<Friend>(predicate: #Predicate { $0.id == fid })
                                if let f = try? self.modelContext.fetch(d2).first {
                                    f.matchedAssetIDs.append(contentsOf: dedupedLocal)
                                    try? self.modelContext.save()
                                }
                            }
                        }
                    }
                    await MainActor.run {
                        let d2 = FetchDescriptor<Friend>(predicate: #Predicate { $0.id == fid })
                        if let f = try? self.modelContext.fetch(d2).first {
                            f.localScanCompleted = true
                            f.localLastScannedDate = nil
                            try? self.modelContext.save()
                        }
                    }
                }

                // B2: Resume iCloud scan if not complete (disabled while iCloudScanEnabled = false)
                guard needsICloud && !Task.isCancelled && iCloudScanEnabled else { continue }

                let iCloudAssets: [PHAsset]
                if let resumeDate = snapshot.iCloudLastScannedDate {
                    iCloudAssets = allAssets.filter { ($0.creationDate ?? .distantPast) < resumeDate }
                } else {
                    iCloudAssets = allAssets
                }
                guard !iCloudAssets.isEmpty else {
                    await MainActor.run {
                        let descriptor = FetchDescriptor<Friend>(predicate: #Predicate { $0.id == fid })
                        if let friend = try? self.modelContext.fetch(descriptor).first {
                            friend.iCloudPassCompleted = true
                            try? self.modelContext.save()
                        }
                    }
                    continue
                }

                await MainActor.run {
                    state.iCloudScanToast = ICloudScanToast(friendName: name, scanned: 0, total: iCloudAssets.count)
                }

                let iCloudResult = try? await service.scanCameraRoll(
                    seedEmbeddings: embeddings,
                    assets: iCloudAssets,
                    matchCap: nil,
                    allowNetwork: true,
                    onProgress: { progress in
                        Task { @MainActor in
                            state.iCloudScanToast = ICloudScanToast(
                                friendName: name, scanned: progress.scanned, total: progress.total
                            )
                            if progress.scanned % 50 == 0, progress.scanned > 0,
                               progress.scanned <= iCloudAssets.count {
                                let asset = iCloudAssets[progress.scanned - 1]
                                let d2 = FetchDescriptor<Friend>(predicate: #Predicate { $0.id == fid })
                                if let f = try? self.modelContext.fetch(d2).first {
                                    f.iCloudLastScannedDate = asset.creationDate
                                    try? self.modelContext.save()
                                }
                            }
                        }
                    },
                    onMatch: nil
                )

                guard !Task.isCancelled else { continue }

                let iCloudIDs = (iCloudResult?.matches ?? []).map { $0.asset.localIdentifier }
                let dedupedCloud = iCloudIDs.filter { !existingSet.contains($0) }

                await MainActor.run { [dedupedCloud] in
                    state.iCloudScanToast = ICloudScanToast(
                        friendName: name, scanned: iCloudAssets.count, total: iCloudAssets.count, isComplete: true
                    )
                    let descriptor = FetchDescriptor<Friend>(predicate: #Predicate { $0.id == fid })
                    if let friend = try? self.modelContext.fetch(descriptor).first {
                        if !dedupedCloud.isEmpty {
                            friend.matchedAssetIDs.append(contentsOf: dedupedCloud)
                        }
                        friend.iCloudPassCompleted = true
                        friend.lastScannedAt = Date()
                        try? self.modelContext.save()
                    }
                }

                try? await Task.sleep(for: .seconds(2))
                await MainActor.run {
                    if state.iCloudScanToast?.isComplete == true {
                        state.iCloudScanToast = nil
                    }
                }
            }
        }
        appState.backgroundScanTask = newTask
    }
}

// MARK: - iCloud scan toast

private struct ICloudScanToastView: View {
    let toast: ICloudScanToast

    var body: some View {
        HStack(spacing: 12) {
            if toast.isComplete {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 18))
            } else {
                ProgressView()
                    .scaleEffect(0.85)
                    .frame(width: 18, height: 18)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(toast.isComplete
                     ? "iCloud scan complete — \(toast.friendName)"
                     : "Scanning iCloud for \(toast.friendName)")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                if toast.total > 0 {
                    ProgressView(value: Double(toast.scanned), total: Double(toast.total))
                        .tint(toast.isComplete ? .green : .blue)

                    Text("\(toast.scanned) / \(toast.total) photos")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }
}

#Preview {
    ContentView()
}
