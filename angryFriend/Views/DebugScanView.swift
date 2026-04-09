import SwiftUI
import Photos

// MARK: - Debug scan view (temporary testing tool)

struct DebugScanView: View {
    @Environment(AppState.self) private var appState

    @State private var threshold: Float = FaceMatchingService.matchThreshold
    @State private var matches: [MatchedAsset] = []
    @State private var scanned: Int = 0
    @State private var total: Int = 0
    @State private var isScanning = false
    @State private var scanTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var sortByScore = true

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controlsBar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.bar)

                Divider()

                if matches.isEmpty && !isScanning {
                    emptyState
                } else {
                    resultsGrid
                }
            }
            .navigationTitle("Debug Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        scanTask?.cancel()
                        appState.screen = .seedPicker
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Toggle(isOn: $sortByScore) {
                        Text("Score")
                    }
                    .toggleStyle(.button)
                    .font(.caption)
                }
            }
        }
        .onDisappear { scanTask?.cancel() }
    }

    // MARK: Controls

    @ViewBuilder
    private var controlsBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Threshold")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(String(format: "%.2f", threshold))
                    .font(.system(.subheadline, design: .monospaced).weight(.bold))
                    .foregroundStyle(.orange)
                    .frame(width: 36, alignment: .trailing)
            }
            Slider(value: $threshold, in: 0.10...0.60, step: 0.01)
                .tint(.orange)

            HStack(spacing: 12) {
                Button(action: startScan) {
                    Label(isScanning ? "Re-scan" : "Start Scan",
                          systemImage: isScanning ? "arrow.clockwise" : "magnifyingglass")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)

                if isScanning {
                    Button("Stop") {
                        scanTask?.cancel()
                        isScanning = false
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }

                Spacer()

                progressLabel
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var progressLabel: some View {
        if total > 0 {
            HStack(spacing: 4) {
                if isScanning {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 14, height: 14)
                }
                Text("\(scanned)/\(total) · \(matches.count) matches")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Results grid

    @ViewBuilder
    private var resultsGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(sortedMatches, id: \.asset.localIdentifier) { match in
                    DebugPhotoCell(asset: match.asset, similarity: match.similarity)
                }
            }
            .padding(.top, 2)
        }
    }

    private var sortedMatches: [MatchedAsset] {
        sortByScore
            ? matches.sorted { $0.similarity > $1.similarity }
            : matches
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Tap Start Scan to find matches")
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: Scan logic

    private func startScan() {
        scanTask?.cancel()
        matches = []
        scanned = 0
        total = 0
        errorMessage = nil
        isScanning = true

        let threshold = self.threshold
        let seedImages = appState.seedImages

        scanTask = Task {
            do {
                let service = try FaceMatchingService()
                let assets = await PhotoLibraryService.shared.fetchAllCameraRollAssets()

                await MainActor.run { self.total = assets.count }

                let seedEmbeddings = try await service.extractSeedEmbeddings(from: seedImages)

                // Pass 1: local photos only (fast)
                let pass1 = try await service.scanCameraRoll(
                    seedEmbeddings: seedEmbeddings,
                    assets: assets,
                    matchThreshold: threshold,
                    matchCap: nil,
                    onProgress: { p in
                        Task { @MainActor in self.scanned = p.scanned }
                    },
                    onMatch: { match in
                        Task { @MainActor in self.matches.append(match) }
                    }
                )

                guard !Task.isCancelled else { return }

                // Pass 2: iCloud photos (network enabled, skip already-scanned)
                // scannedIDs comes directly from pass1 — no per-asset MainActor dispatch
                let iCloudAssets = assets.filter { !pass1.scannedIDs.contains($0.localIdentifier) }
                guard !iCloudAssets.isEmpty else { return }

                await MainActor.run {
                    self.scanned = 0
                    self.total = iCloudAssets.count
                }

                _ = try await service.scanCameraRoll(
                    seedEmbeddings: seedEmbeddings,
                    assets: iCloudAssets,
                    matchThreshold: threshold,
                    matchCap: nil,
                    allowNetwork: true,
                    onProgress: { p in
                        Task { @MainActor in self.scanned = p.scanned }
                    },
                    onMatch: { match in
                        Task { @MainActor in self.matches.append(match) }
                    }
                )
            } catch is CancellationError {
                // stopped by user — leave results as-is
            } catch {
                await MainActor.run { self.errorMessage = error.localizedDescription }
            }
            await MainActor.run { self.isScanning = false }
        }
    }
}

// MARK: - Photo cell

private struct DebugPhotoCell: View {
    let asset: PHAsset
    let similarity: Float

    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.secondary.opacity(0.15)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                ProgressView().scaleEffect(0.7)
            }

            Text(String(format: "%.2f", similarity))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(scoreColor.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .padding(3)
        }
        .aspectRatio(1, contentMode: .fit)  // square from outer constraint
        .clipped()
        .task {
            image = await PhotoLibraryService.shared.loadImage(
                for: asset,
                targetSize: CGSize(width: 200, height: 200)
            )
        }
    }

    private var scoreColor: Color {
        switch similarity {
        case 0.5...: return .green
        case 0.35..<0.5: return .orange
        default: return .red
        }
    }
}
