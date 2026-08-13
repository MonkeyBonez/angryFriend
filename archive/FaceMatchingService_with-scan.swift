import Vision
import Photos
import UIKit
import CoreML
import os

// MLModel is thread-safe for concurrent inference
extension MLModel: @unchecked Sendable {}

// MARK: - Types

struct MatchedAsset {
    let asset: PHAsset
    let similarity: Float   // higher = better match
    let faceBoundingBox: CGRect  // Vision-normalized bbox of best-matching face (y-up, origin bottom-left)
}

struct ScanProgress {
    var scanned: Int
    var total: Int
    var matchesFound: Int
}

// MARK: - Service

actor FaceMatchingService {

    // Threshold validated on real test sets (PhotosOfFriends/PhotosOfRandoms):
    // 0.27 gains +6–9pt recall over 0.29 at 0% FPR across 279 negatives, with margin
    // above the highest-scoring stranger face (~0.257). 0.26 is the aggressive edge.
    static let matchThreshold: Float = 0.27
    static let targetMatchCount = 100
    // MUST stay below the CPU core count. VNImageRequestHandler.perform is a BLOCKING
    // synchronous call; the scan workers run on Swift's cooperative thread pool (~= core
    // count). If as many workers as cores all block inside perform at once, Vision's
    // internal work has no free thread to run on and the scan deadlocks. 8 froze on a
    // 6-core device; 4 leaves headroom. Do NOT raise past ~4 without moving perform off
    // the cooperative pool (dedicated DispatchQueue).
    static let scanConcurrency = 4
    static let iCloudScanConcurrency = 10

    // Two-stage detection: cheap face-rectangle pass on a small thumbnail rejects the
    // face-less majority of a camera roll before paying for a 1024 decode + landmarks.
    static let stageAThumbSize = CGSize(width: 384, height: 384)
    // Normalized min face width, matching the stage-B 28px floor at 1024px (resolution-independent).
    static let minFaceNormalizedWidth: CGFloat = 28.0 / 1024.0

    private static let logger = Logger(subsystem: "com.angryFriend", category: "FaceMatching")

    private let mlModel: MLModel

    init() throws {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        guard let modelURL = Bundle.main.url(forResource: "MobileFaceNet", withExtension: "mlmodelc") else {
            throw MatchError.modelNotFound
        }
        self.mlModel = try MLModel(contentsOf: modelURL, configuration: config)
    }

    // MARK: Orientation normalization

    private static func normalizeOrientation(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        return UIGraphicsImageRenderer(size: image.size).image { _ in image.draw(at: .zero) }
    }

    // MARK: - 2-point eye alignment (ArcFace-compatible 112×112 chip)
    //
    // Aligns using eye centroids only. Corrects scale and rotation so the eye midpoint
    // lands at (55.91, 51.60) with an inter-eye distance of 35.24px in the 112×112 output.
    //
    // Vision landmark coords (normalizedPoints) are bbox-local, y-up, origin bottom-left.
    // toPixel() converts them to full-image CGImage pixel coords (y-down, origin top-left).

    private static func alignedFaceChip(cgImage: CGImage, face: VNFaceObservation) -> CGImage? {
        guard let landmarks = face.landmarks else { return nil }

        let imageW = CGFloat(cgImage.width)
        let imageH = CGFloat(cgImage.height)
        let box    = face.boundingBox

        // Convert bbox-local Vision point (y-up) → CGImage pixel (y-down)
        func toPixel(_ p: CGPoint) -> CGPoint {
            let fullX = box.origin.x + p.x * box.width
            let fullY = box.origin.y + p.y * box.height
            return CGPoint(x: fullX * imageW, y: (1.0 - fullY) * imageH)
        }

        func centroid(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
            guard let region, !region.normalizedPoints.isEmpty else { return nil }
            let pts = region.normalizedPoints
            let n   = CGFloat(pts.count)
            let sum = pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            return toPixel(CGPoint(x: sum.x / n, y: sum.y / n))
        }

        guard let rightEyePx = centroid(landmarks.rightEye),
              let leftEyePx  = centroid(landmarks.leftEye) else { return nil }

        // Ensure eyeA is the leftmost (smaller x) eye in image coords
        let (eyeA, eyeB) = rightEyePx.x < leftEyePx.x
            ? (rightEyePx, leftEyePx)
            : (leftEyePx, rightEyePx)

        let outputSize = CGSize(width: 112, height: 112)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0  // exactly 112×112 pixels, no Retina scaling
        let renderer = UIGraphicsImageRenderer(size: outputSize, format: format)
        let srcImage = UIImage(cgImage: cgImage)

        let dx      = eyeB.x - eyeA.x
        let dy      = eyeB.y - eyeA.y
        let eyeDist = hypot(dx, dy)
        guard eyeDist > 4 else { return nil }

        let angle  = atan2(dy, dx)
        let scale  = 35.24 / eyeDist
        let midX   = (eyeA.x + eyeB.x) / 2
        let midY   = (eyeA.y + eyeB.y) / 2

        let transform = CGAffineTransform.identity
            .translatedBy(x: 55.91, y: 51.60)
            .scaledBy(x: scale, y: scale)
            .rotated(by: -angle)
            .translatedBy(x: -midX, y: -midY)

        let chip = renderer.image { ctx in
            ctx.cgContext.concatenate(transform)
            srcImage.draw(in: CGRect(x: 0, y: 0, width: imageW, height: imageH))
        }
        return chip.cgImage
    }

    // MARK: Pixel buffer from CGImage (112×112)

    private static func pixelBuffer(from cgImage: CGImage) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, 112, 112,
                                  kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess,
              let pixelBuffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: 112, height: 112,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: 112, height: 112))
        return pixelBuffer
    }

    // MARK: CoreML embedding extraction via direct MLModel.prediction()

    private static func extractEmbedding(from chip: CGImage, using model: MLModel) -> FaceEmbedding? {
        guard let pb = pixelBuffer(from: chip) else { return nil }

        guard let featureProvider = try? MLDictionaryFeatureProvider(dictionary: [
            "input_1": MLFeatureValue(pixelBuffer: pb)
        ]) else { return nil }

        guard let output = try? model.prediction(from: featureProvider),
              let arr = output.featureValue(for: "var_950")?.multiArrayValue else { return nil }

        var vec = (0..<arr.count).map { Float(truncating: arr[$0]) }
        let norm = sqrt(vec.reduce(0) { $0 + $1 * $1 })

        logger.debug("Embedding norm: \(norm, format: .fixed(precision: 4)), first values: [\(vec[0], format: .fixed(precision: 4)), \(vec[1], format: .fixed(precision: 4)), \(vec[2], format: .fixed(precision: 4))]")

        guard norm > 0 else { return nil }
        vec = vec.map { $0 / norm }
        return FaceEmbedding(vector: vec)
    }

    // MARK: Face detection for seed picker (returns display crops + bboxes)

    static func detectFaceCrops(in image: UIImage) async -> [(crop: UIImage, normalizedBox: CGRect)] {
        let normalized = normalizeOrientation(image)
        guard let cgImage = normalized.cgImage else { return [] }

        let req = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        guard (try? handler.perform([req])) != nil,
              let faces = req.results, !faces.isEmpty else { return [] }

        let w = CGFloat(cgImage.width), h = CGFloat(cgImage.height)
        var results: [(crop: UIImage, normalizedBox: CGRect)] = []

        for face in faces {
            let box = face.boundingBox
            // Pad 40% and flip y for CGImage space
            let pad: CGFloat = 0.4
            let ex = max(0, box.origin.x - pad * box.width)
            let ey = box.origin.y - pad * box.height
            let ew = min(box.width * (1 + 2 * pad), 1 - ex)
            let eh = box.height * (1 + 2 * pad)
            let flippedY = 1.0 - ey - eh
            let cropRect = CGRect(
                x: ex * w, y: max(0, flippedY * h),
                width: ew * w, height: min(eh * h, h - max(0, flippedY * h))
            )
            guard let cropped = cgImage.cropping(to: cropRect) else { continue }
            results.append((crop: UIImage(cgImage: cropped), normalizedBox: box))
        }
        return results
    }

    // MARK: Single-image seed extraction

    func extractSeedEmbedding(from image: UIImage) throws -> FaceEmbedding {
        let normalized = FaceMatchingService.normalizeOrientation(image)
        guard let cgImage = normalized.cgImage else { throw MatchError.invalidImage }

        let landmarkReq = VNDetectFaceLandmarksRequest()
        let handler     = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([landmarkReq])
        guard let face = landmarkReq.results?.first else { throw MatchError.noFaceFound }

        let crop = FaceMatchingService.alignedFaceChip(cgImage: cgImage, face: face)
            ?? FaceMatchingService.cropToFace(cgImage: cgImage, box: face.boundingBox)

        guard let embedding = FaceMatchingService.extractEmbedding(from: crop, using: mlModel) else {
            throw MatchError.embeddingFailed
        }

        FaceMatchingService.logger.info("Seed embedding extracted successfully")
        return embedding
    }

    // MARK: Multi-image seed extraction

    func extractSeedEmbeddings(from images: [UIImage]) throws -> [FaceEmbedding] {
        var embeddings: [FaceEmbedding] = []
        for image in images {
            // Skip low-quality seeds silently (already warned if all are low-quality)
            if let emb = try? extractSeedEmbedding(from: image) {
                embeddings.append(emb)
            }
        }
        guard !embeddings.isEmpty else { throw MatchError.noFaceFound }
        return embeddings
    }

    // MARK: All-face embedding (identity discovery + per-card face recovery)

    private nonisolated static func embedAllFaces(
        in cgImage: CGImage,
        model: MLModel
    ) -> [(embedding: FaceEmbedding, box: CGRect)] {
        autoreleasepool {
            let req = VNDetectFaceLandmarksRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            guard (try? handler.perform([req])) != nil, let faces = req.results else { return [] }

            var results: [(embedding: FaceEmbedding, box: CGRect)] = []
            for face in faces {
                let facePixelWidth = face.boundingBox.width * CGFloat(cgImage.width)
                guard facePixelWidth >= 28 else { continue }
                let crop = alignedFaceChip(cgImage: cgImage, face: face)
                    ?? cropToFace(cgImage: cgImage, box: face.boundingBox)
                guard let embedding = extractEmbedding(from: crop, using: model) else { continue }
                results.append((embedding, face.boundingBox))
            }
            return results
        }
    }

    private static func cosine(_ a: FaceEmbedding, _ b: FaceEmbedding) -> Float {
        zip(a.vector, b.vector).reduce(0) { $0 + $1.0 * $1.1 }
    }

    // MARK: Dominant identity discovery (manual picks — no seed photo)

    /// Randomly samples the pool, embeds every face, greedily clusters by cosine
    /// similarity, and returns embeddings of the identity that appears in the most
    /// photos. A pool that's mostly one person surfaces that person; a mixed pool
    /// still surfaces whoever recurs most. Empty if no usable faces were found.
    func dominantIdentityEmbeddings(
        in assets: [PHAsset],
        sampleLimit: Int = 12
    ) async -> [FaceEmbedding] {
        let sample = Array(assets.shuffled().prefix(sampleLimit))
        let model = mlModel

        // 3 loaders — the Vision+CoreML work funnels through blocking perform calls,
        // so stay well under scanConcurrency's cooperative-pool ceiling.
        var facesPerPhoto: [(photo: Int, faces: [(embedding: FaceEmbedding, box: CGRect)])] = []
        await withTaskGroup(of: (Int, [(embedding: FaceEmbedding, box: CGRect)]).self) { group in
            var iterator = sample.enumerated().makeIterator()
            var pending = 0
            while pending < 3, let (i, asset) = iterator.next() {
                group.addTask { (i, await Self.embedFacesInAsset(asset, model: model)) }
                pending += 1
            }
            for await (photo, faces) in group {
                pending -= 1
                if !faces.isEmpty { facesPerPhoto.append((photo, faces)) }
                if let (nextI, nextAsset) = iterator.next() {
                    group.addTask { (nextI, await Self.embedFacesInAsset(nextAsset, model: model)) }
                    pending += 1
                }
            }
        }

        // Greedy clustering: link each face to the best cluster above threshold
        // (max-linkage), else start a new one. Rank clusters by distinct photos.
        struct Cluster {
            var members: [FaceEmbedding]
            var photos: Set<Int>
        }
        var clusters: [Cluster] = []
        for (photo, faces) in facesPerPhoto {
            for (embedding, _) in faces {
                var bestIndex: Int? = nil
                var bestSim = Self.matchThreshold
                for (i, cluster) in clusters.enumerated() {
                    let sim = cluster.members.map { Self.cosine($0, embedding) }.max() ?? 0
                    if sim >= bestSim {
                        bestSim = sim
                        bestIndex = i
                    }
                }
                if let i = bestIndex {
                    clusters[i].members.append(embedding)
                    clusters[i].photos.insert(photo)
                } else {
                    clusters.append(Cluster(members: [embedding], photos: [photo]))
                }
            }
        }

        guard let winner = clusters.max(by: {
            ($0.photos.count, $0.members.count) < ($1.photos.count, $1.members.count)
        }) else {
            Self.logger.info("Identity discovery: no faces in \(facesPerPhoto.count)/\(sample.count) sampled photos")
            return []
        }
        Self.logger.info("Identity discovery: \(clusters.count) identities across \(facesPerPhoto.count) photos; winner in \(winner.photos.count) photos (\(winner.members.count) faces)")
        return Array(winner.members.prefix(3))
    }

    private nonisolated static func embedFacesInAsset(
        _ asset: PHAsset,
        model: MLModel
    ) async -> [(embedding: FaceEmbedding, box: CGRect)] {
        let targetSize = CGSize(width: 1024, height: 1024)
        var image = await PhotoLibraryService.shared.loadImage(
            for: asset, targetSize: targetSize, allowNetwork: false
        )
        if image == nil {
            image = await PhotoLibraryService.shared.loadImage(
                for: asset, targetSize: targetSize, allowNetwork: true
            )
        }
        guard let image, let cgImage = normalizeOrientation(image).cgImage else { return [] }
        return embedAllFaces(in: cgImage, model: model)
    }

    // MARK: Best-matching face lookup (per-card face recovery)

    /// Finds the face in `image` best matching any reference embedding and returns
    /// its Vision-normalized bounding box, or nil if none reaches the match threshold.
    func bestFaceBox(in image: UIImage, matching references: [FaceEmbedding]) -> CGRect? {
        guard !references.isEmpty else { return nil }
        guard let cgImage = Self.normalizeOrientation(image).cgImage else { return nil }

        var bestBox: CGRect? = nil
        var bestSim = Self.matchThreshold
        for (embedding, box) in Self.embedAllFaces(in: cgImage, model: mlModel) {
            let sim = references.map { Self.cosine($0, embedding) }.max() ?? 0
            if sim >= bestSim {
                bestSim = sim
                bestBox = box
            }
        }
        return bestBox
    }

    // MARK: Concurrent camera roll scan

    struct ScanResult {
        let matches: [MatchedAsset]
        let scannedIDs: Set<String>  // asset IDs that loaded successfully (match or no match)
    }

    func scanCameraRoll(
        seedEmbeddings: [FaceEmbedding],
        assets: [PHAsset],
        matchThreshold: Float = FaceMatchingService.matchThreshold,
        matchCap: Int? = FaceMatchingService.targetMatchCount,
        allowNetwork: Bool = false,
        onProgress: @escaping @Sendable (ScanProgress) -> Void,
        onMatch: (@Sendable (MatchedAsset) -> Void)? = nil
    ) async throws -> ScanResult {
        let total = assets.count
        var matches: [MatchedAsset] = []
        var scannedIDs: Set<String> = []
        var scanned = 0
        var stageARejected = 0
        var facesEmbedded = 0
        var iterator = assets.makeIterator()
        // More workers for iCloud pass — bottleneck is network I/O, not compute
        let concurrency = allowNetwork ? Self.iCloudScanConcurrency : Self.scanConcurrency
        let model = mlModel

        let clock = ContinuousClock()
        let scanStart = clock.now
        FaceMatchingService.logger.info("Starting scan: \(total) assets, threshold \(matchThreshold, format: .fixed(precision: 2)), seeds: \(seedEmbeddings.count)")

        try await withThrowingTaskGroup(of: (String, AssetResult).self) { group in
            var pending = 0
            while pending < concurrency, let asset = iterator.next() {
                let id = asset.localIdentifier
                group.addTask {
                    (id, await FaceMatchingService.evaluateAsset(
                        asset, seedEmbeddings: seedEmbeddings, model: model, matchThreshold: matchThreshold, allowNetwork: allowNetwork
                    ))
                }
                pending += 1
            }

            for try await (assetID, result) in group {
                // Exit cleanly if the task was cancelled (e.g. Play Again killed the old scan).
                try Task.checkCancellation()

                pending -= 1
                scanned += 1

                switch result {
                case .loaded(let match, let wasStageARejected, let embedded):
                    scannedIDs.insert(assetID)  // accumulated here, no extra dispatch
                    if wasStageARejected { stageARejected += 1 }
                    facesEmbedded += embedded
                    if let match {
                        matches.append(match)
                        onMatch?(match)
                    }
                case .skipped:
                    break  // image didn't load — don't mark as scanned
                }

                onProgress(ScanProgress(
                    scanned: scanned,
                    total: total,
                    matchesFound: matches.count
                ))

                if let cap = matchCap, matches.count >= cap {
                    group.cancelAll()
                    break
                }

                // Don't schedule more work if already cancelled.
                guard !Task.isCancelled else {
                    group.cancelAll()
                    break
                }

                if let next = iterator.next() {
                    let nextID = next.localIdentifier
                    group.addTask {
                        (nextID, await FaceMatchingService.evaluateAsset(
                            next, seedEmbeddings: seedEmbeddings, model: model, matchThreshold: matchThreshold, allowNetwork: allowNetwork
                        ))
                    }
                    pending += 1
                }
            }
        }

        let elapsed = clock.now - scanStart
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let rate = seconds > 0 ? Double(scanned) / seconds : 0
        let rejectPct = scanned > 0 ? stageARejected * 100 / scanned : 0
        FaceMatchingService.logger.info("Scan complete: \(scanned) scanned, \(stageARejected) stage-A rejected (\(rejectPct)%), \(facesEmbedded) faces embedded, \(matches.count) matches, \(seconds, format: .fixed(precision: 1))s, \(rate, format: .fixed(precision: 1)) photos/s")
        return ScanResult(matches: matches.sorted { $0.similarity > $1.similarity }, scannedIDs: scannedIDs)
    }

    // MARK: Per-asset evaluation (static → runs concurrently off actor)

    private enum AssetResult {
        // image loaded; match is nil if no face passed threshold. stageARejected marks
        // photos that were dropped by the cheap thumbnail pass (no full-res work done).
        case loaded(match: MatchedAsset?, stageARejected: Bool, facesEmbedded: Int)
        case skipped                 // image failed to load (e.g. iCloud-only)
    }

    private nonisolated static func evaluateAsset(
        _ asset: PHAsset,
        seedEmbeddings: [FaceEmbedding],
        model: MLModel,
        matchThreshold: Float,
        allowNetwork: Bool = false
    ) async -> AssetResult {
        // --- Stage A: cheap reject on a small thumbnail ---
        // PhotoKit serves thumbnails from precomputed caches, so this is far cheaper than
        // a full 1024 decode + landmark detection. Photos with no qualifying face exit here.
        guard let thumb = await PhotoLibraryService.shared.loadImage(
            for: asset,
            targetSize: stageAThumbSize,
            allowNetwork: allowNetwork,
            fastMode: true
        ) else { return .skipped }

        let normThumb = normalizeOrientation(thumb)
        guard let thumbCG = normThumb.cgImage else {
            return .loaded(match: nil, stageARejected: true, facesEmbedded: 0)
        }

        let stageAFaces: [VNFaceObservation] = autoreleasepool {
            let rectReq = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cgImage: thumbCG, options: [:])
            guard (try? handler.perform([rectReq])) != nil, let faces = rectReq.results else { return [] }
            // Normalized width is resolution-independent, so this floor matches stage B's 28px.
            return faces.filter { $0.boundingBox.width >= minFaceNormalizedWidth }
        }

        guard !stageAFaces.isEmpty else {
            return .loaded(match: nil, stageARejected: true, facesEmbedded: 0)
        }

        // --- Stage B: full pipeline, only for face-bearing photos ---
        guard let image = await PhotoLibraryService.shared.loadImage(
            for: asset,
            targetSize: CGSize(width: 1024, height: 1024),
            allowNetwork: allowNetwork,
            fastMode: true
        ) else { return .skipped }

        let normalized = normalizeOrientation(image)
        guard let cgImage = normalized.cgImage else {
            return .loaded(match: nil, stageARejected: false, facesEmbedded: 0)
        }

        var facesEmbedded = 0
        let match: MatchedAsset? = autoreleasepool { () -> MatchedAsset? in
            let landmarkReq = VNDetectFaceLandmarksRequest()
            // Seed with the stage-A boxes so Vision skips re-detection at 1024. Normalized
            // coords transfer across resolutions (both loads use .aspectFit contentMode).
            landmarkReq.inputFaceObservations = stageAFaces
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

            var faces: [VNFaceObservation] = []
            if (try? handler.perform([landmarkReq])) != nil, let r = landmarkReq.results, !r.isEmpty {
                faces = r
            } else {
                // Fallback: rare coordinate/EXIF mismatch — retry detecting from scratch.
                let retryReq = VNDetectFaceLandmarksRequest()
                let retryHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                guard (try? retryHandler.perform([retryReq])) != nil,
                      let r2 = retryReq.results, !r2.isEmpty else { return nil }
                faces = r2
            }

            var best: MatchedAsset? = nil
            for face in faces {
                // Min face size filter — skip faces < 28px wide
                let facePixelWidth = face.boundingBox.width * CGFloat(cgImage.width)
                guard facePixelWidth >= 28 else { continue }

                let crop = alignedFaceChip(cgImage: cgImage, face: face)
                    ?? cropToFace(cgImage: cgImage, box: face.boundingBox)

                guard let embedding = extractEmbedding(from: crop, using: model) else { continue }
                facesEmbedded += 1

                // Max-of-similarities across all seed embeddings (L2-normalised → dot = cosine)
                let embVec = embedding.vector
                let similarity: Float = seedEmbeddings.map { seed in
                    zip(seed.vector, embVec).reduce(0) { $0 + $1.0 * $1.1 }
                }.max() ?? 0

                logger.debug("Face similarity: \(similarity, format: .fixed(precision: 4)) (threshold: \(matchThreshold, format: .fixed(precision: 2)))")

                if similarity > matchThreshold {
                    if best == nil || similarity > best!.similarity {
                        best = MatchedAsset(asset: asset, similarity: similarity, faceBoundingBox: face.boundingBox)
                    }
                }
            }
            return best
        }
        return .loaded(match: match, stageARejected: false, facesEmbedded: facesEmbedded)
    }

    // MARK: Y-flip padded bbox crop (fallback when alignment fails completely)

    static func cropToFace(cgImage: CGImage, box: CGRect) -> CGImage {
        let w   = CGFloat(cgImage.width)
        let h   = CGFloat(cgImage.height)
        let pad: CGFloat = 0.25

        let expandedX = box.origin.x - pad * box.width
        let expandedY = box.origin.y - pad * box.height
        let expandedW = box.width  * (1 + 2 * pad)
        let expandedH = box.height * (1 + 2 * pad)

        let flippedY = 1.0 - expandedY - expandedH

        let cropRect = CGRect(
            x:      max(0, expandedX * w),
            y:      max(0, flippedY * h),
            width:  min(expandedW * w, w - max(0, expandedX * w)),
            height: min(expandedH * h, h - max(0, flippedY * h))
        )

        return cgImage.cropping(to: cropRect) ?? cgImage
    }

    // MARK: Error

    enum MatchError: LocalizedError {
        case invalidImage, noFaceFound, embeddingFailed, modelNotFound
        var errorDescription: String? {
            switch self {
            case .invalidImage:    return "Invalid image"
            case .noFaceFound:     return "No face detected in seed photo — try a clearer front-facing photo."
            case .embeddingFailed: return "Could not generate face embedding."
            case .modelNotFound:   return "MobileFaceNet model not found in app bundle."
            }
        }
    }
}
