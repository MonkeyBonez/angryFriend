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

    static let matchThreshold: Float = 0.29
    static let targetMatchCount = 100
    static let scanConcurrency = 4
    static let iCloudScanConcurrency = 10

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
        var iterator = assets.makeIterator()
        // More workers for iCloud pass — bottleneck is network I/O, not compute
        let concurrency = allowNetwork ? Self.iCloudScanConcurrency : Self.scanConcurrency
        let model = mlModel

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
                pending -= 1
                scanned += 1

                switch result {
                case .loaded(let match):
                    scannedIDs.insert(assetID)  // accumulated here, no extra dispatch
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

        FaceMatchingService.logger.info("Scan complete: \(scanned) scanned, \(matches.count) matches found")
        return ScanResult(matches: matches.sorted { $0.similarity > $1.similarity }, scannedIDs: scannedIDs)
    }

    // MARK: Per-asset evaluation (static → runs concurrently off actor)

    private enum AssetResult {
        case loaded(MatchedAsset?)   // image loaded; inner nil = no match
        case skipped                 // image failed to load (e.g. iCloud-only)
    }

    private static func evaluateAsset(
        _ asset: PHAsset,
        seedEmbeddings: [FaceEmbedding],
        model: MLModel,
        matchThreshold: Float,
        allowNetwork: Bool = false
    ) async -> AssetResult {
        // Step 3: resolution bump to 1024×1024 for better face chip quality
        guard let image = await PhotoLibraryService.shared.loadImage(
            for: asset,
            targetSize: CGSize(width: 1024, height: 1024),
            allowNetwork: allowNetwork,
            fastMode: true
        ) else { return .skipped }

        let normalized = normalizeOrientation(image)
        guard let cgImage = normalized.cgImage else { return .loaded(nil) }

        let match: MatchedAsset? = autoreleasepool { () -> MatchedAsset? in
            let landmarkReq = VNDetectFaceLandmarksRequest()
            let handler     = VNImageRequestHandler(cgImage: cgImage, options: [:])
            guard (try? handler.perform([landmarkReq])) != nil,
                  let faces = landmarkReq.results, !faces.isEmpty
            else { return nil }

            var best: MatchedAsset? = nil

            for face in faces {
                // Min face size filter — skip faces < 28px wide
                let facePixelWidth = face.boundingBox.width * CGFloat(cgImage.width)
                guard facePixelWidth >= 28 else { continue }

                let crop = alignedFaceChip(cgImage: cgImage, face: face)
                    ?? cropToFace(cgImage: cgImage, box: face.boundingBox)

                guard let embedding = extractEmbedding(from: crop, using: model) else { continue }

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
        return .loaded(match)
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
