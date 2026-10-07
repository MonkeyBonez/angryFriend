import Vision
import Photos
import UIKit
import CoreML
import os

// MLModel is thread-safe for concurrent inference
extension MLModel: @unchecked Sendable {}

// MARK: - Types

/// One photo where the discovered friend's face was found.
struct FriendPhotoMatch {
    let asset: PHAsset
    let faceBoundingBox: CGRect   // Vision-normalized bbox (y-up, origin bottom-left)
    let isSoloFace: Bool          // true if this photo has exactly one face — a clean cover candidate
}

struct IdentityDiscoveryResult {
    let identity: [FaceEmbedding]      // up to 3 representative embeddings of the winning identity
    let matches: [FriendPhotoMatch]    // every input photo the identity was found in
}

/// One photo a rescan found the friend in. Plain values so it can cross actors.
struct FoundFace: Sendable {
    let assetID: String
    let faceBoundingBox: CGRect   // Vision-normalized bbox (y-up, origin bottom-left)
}

/// What a background-scan search turned up across a batch of photos.
nonisolated struct FriendsSearchResult: Sendable {
    var found: [UUID: [FoundFace]] = [:]   // per friend
    var checkedIDs: Set<String> = []       // looked at properly: matched or ruled out
    var cloudIDs: [String] = []            // original only in iCloud, and the copy here wasn't enough to rule it out
    var failedIDs: [String] = []           // didn't load at all
    var completed = true                   // false if stopped before every photo was looked at
}

/// One photo for the scan to check, and which friends to check it against.
nonisolated struct ScanCandidate: @unchecked Sendable {
    let asset: PHAsset
    let friendIDs: [UUID]
}

nonisolated enum ScanMode: Sendable {
    case local      // the library walk: downloads iCloud-only photos inline when online
    case download   // retrying photos queued for iCloud
}

// MARK: - Service

actor FaceMatchingService {

    // Threshold validated on real test sets (PhotosOfFriends/PhotosOfRandoms):
    // 0.27 gains +6–9pt recall over 0.29 at 0% FPR across 279 negatives, with margin
    // above the highest-scoring stranger face (~0.257). 0.26 is the aggressive edge.
    static let matchThreshold: Float = 0.27

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

    private nonisolated static func normalizeOrientation(_ image: UIImage) -> UIImage {
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

        guard norm > 0 else { return nil }
        vec = vec.map { $0 / norm }
        return FaceEmbedding(vector: vec)
    }

    // MARK: All-face embedding (identity discovery)

    private nonisolated static func embedAllFaces(
        in cgImage: CGImage,
        model: MLModel
    ) -> [(embedding: FaceEmbedding, box: CGRect)] {
        autoreleasepool {
            let req = VNDetectFaceLandmarksRequest()
            #if targetEnvironment(simulator)
            // No Neural Engine in the Simulator: "Could not create inference context".
            if let cpu = MLComputeDevice.allComputeDevices.first(where: { if case .cpu = $0 { true } else { false } }) {
                req.setComputeDevice(cpu, for: .main)
            }
            #endif
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([req])
            } catch {
                logger.error("Face detection failed: \(error.localizedDescription)")
                return []
            }
            guard let faces = req.results else { return [] }

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

    private nonisolated static func cosine(_ a: FaceEmbedding, _ b: FaceEmbedding) -> Float {
        zip(a.vector, b.vector).reduce(0) { $0 + $1.0 * $1.1 }
    }

    // MARK: Off the cooperative pool
    //
    // `VNImageRequestHandler.perform` and `MLModel.prediction` block their thread.
    // Run on Swift's cooperative pool (~1 thread per core) they starve it — of
    // the threads Vision needs internally (8 workers once deadlocked a 6-core
    // phone) and of the threads the UI's own async work runs on. So the blocking
    // part runs on its own GCD queue, at the QoS of whoever asked: the background
    // scan at utility, identity discovery at user-initiated.

    private nonisolated static let visionQueue = DispatchQueue(
        label: "com.angryFriend.vision", qos: .utility, attributes: .concurrent
    )

    private nonisolated static func embedOffPool(
        _ image: UIImage,
        model: MLModel,
        qos: DispatchQoS
    ) async -> [(embedding: FaceEmbedding, box: CGRect)] {
        await withCheckedContinuation { cont in
            visionQueue.async(qos: qos, flags: .enforceQoS) {
                guard let cgImage = normalizeOrientation(image).cgImage else {
                    cont.resume(returning: [])
                    return
                }
                cont.resume(returning: embedAllFaces(in: cgImage, model: model))
            }
        }
    }

    /// The caller's priority, as a GCD QoS.
    private nonisolated static var currentQoS: DispatchQoS {
        switch Task.currentPriority {
        case .high, .userInitiated: return .userInitiated
        case .medium: return .default
        default: return .utility
        }
    }

    // MARK: - Dominant identity discovery (the core of "pick photos yourself")
    //
    // Embeds every face in every provided photo, greedily clusters by cosine
    // similarity, and returns the identity that recurs across the most distinct
    // photos — i.e. whoever the user actually meant when they picked this batch,
    // even if other people also appear in some of the shots. Runs across ALL
    // provided assets (no random sampling) so a photo that only has the friend
    // in a group shot still counts as evidence.
    func discoverFriendIdentity(
        in assets: [PHAsset],
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> IdentityDiscoveryResult {
        let model = mlModel
        let total = assets.count

        // 3 loaders — VNImageRequestHandler.perform is a BLOCKING synchronous call, and
        // these workers run on Swift's cooperative thread pool (~= CPU core count). Too
        // many concurrent blocking workers can starve Vision's own internal work of a
        // free thread and deadlock, so stay well under the core count.
        var facesPerPhoto: [(photo: Int, faces: [(embedding: FaceEmbedding, box: CGRect)])] = []
        var scanned = 0
        await withTaskGroup(of: (Int, [(embedding: FaceEmbedding, box: CGRect)]).self) { group in
            var iterator = assets.enumerated().makeIterator()
            var pending = 0
            while pending < 3, let (i, asset) = iterator.next() {
                group.addTask { (i, await Self.embedFacesInAsset(asset, model: model)) }
                pending += 1
            }
            for await (photo, faces) in group {
                pending -= 1
                if !faces.isEmpty { facesPerPhoto.append((photo, faces)) }
                scanned += 1
                onProgress?(scanned, total)
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
            Self.logger.info("Identity discovery: no faces found in \(facesPerPhoto.count)/\(assets.count) photos")
            return IdentityDiscoveryResult(identity: [], matches: [])
        }
        Self.logger.info("Identity discovery: \(clusters.count) identities across \(facesPerPhoto.count) photos; winner in \(winner.photos.count) photos (\(winner.members.count) faces)")

        // Build the per-photo match list: for each photo containing the winning
        // identity, keep the winner's box and whether that photo has only one face.
        var matches: [FriendPhotoMatch] = []
        for (photo, faces) in facesPerPhoto {
            guard winner.photos.contains(photo) else { continue }
            var bestBox: CGRect? = nil
            var bestSim = Self.matchThreshold
            for (embedding, box) in faces {
                let sim = winner.members.map { Self.cosine($0, embedding) }.max() ?? 0
                if sim >= bestSim {
                    bestSim = sim
                    bestBox = box
                }
            }
            guard let box = bestBox else { continue }
            matches.append(FriendPhotoMatch(asset: assets[photo], faceBoundingBox: box, isSoloFace: faces.count == 1))
        }

        return IdentityDiscoveryResult(identity: Array(winner.members.prefix(3)), matches: matches)
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
        guard let image else { return [] }
        return await embedOffPool(image, model: model, qos: .userInitiated)
    }

    // MARK: - Background scan (find saved friends in the library)
    //
    // Nothing to cluster: each photo is loaded once, its faces embedded once, and
    // every face compared against each friend the photo is being checked for.
    // A photo whose original is only in iCloud is downloaded on the spot when
    // the phone is online. Offline, the copy already on the phone is checked
    // instead, and the photo queued for a download if that copy is too small to
    // trust or shows faces that didn't match.

    /// Shortest side a local iCloud stand-in must have before a "no match" on it
    /// is trusted. Small renditions still find faces, but a friend in the
    /// background of one is too few pixels to recognise.
    nonisolated static let minTriageSide = 480

    func findFriends(
        identities: [UUID: [FaceEmbedding]],
        in candidates: [ScanCandidate],
        mode: ScanMode,
        control: ScanControl,
        onMatch: @escaping @Sendable (UUID, FoundFace) -> Void
    ) async -> FriendsSearchResult {
        let model = mlModel
        let qos = Self.currentQoS
        var result = FriendsSearchResult()
        var stopped = false

        await withTaskGroup(of: (String, AssetCheck).self) { group in
            var iterator = candidates.makeIterator()
            var running = 0
            var exhausted = false

            while true {
                // Keep `workers` photos in flight. A hold (snipping, identifying)
                // or a hot phone stops new photos from starting; the ones already
                // going finish, so the scan yields within about one photo.
                while running < control.workers, !exhausted, !stopped {
                    if control.isStopped || Task.isCancelled { stopped = true; break }
                    if control.mustWait {
                        if running > 0 { break }
                        try? await Task.sleep(for: .milliseconds(300))
                        continue
                    }
                    guard let candidate = iterator.next() else { exhausted = true; break }
                    group.addTask {
                        (candidate.asset.localIdentifier,
                         await Self.check(candidate, identities: identities, mode: mode, model: model, qos: qos))
                    }
                    running += 1
                }
                guard running > 0, let (assetID, check) = await group.next() else { break }
                running -= 1

                switch check {
                case .checked(let matches, let needsDownload):
                    for (friendID, box) in matches {
                        let face = FoundFace(assetID: assetID, faceBoundingBox: box)
                        result.found[friendID, default: []].append(face)
                        onMatch(friendID, face)
                    }
                    if needsDownload {
                        result.cloudIDs.append(assetID)
                    } else {
                        result.checkedIDs.insert(assetID)
                    }
                case .failed:
                    result.failedIDs.append(assetID)
                }
            }
        }

        result.completed = !stopped
        let matched = result.found.values.reduce(0) { $0 + $1.count }
        Self.logger.info("Scan batch (\(mode == .local ? "local" : "download")): \(candidates.count) photos, \(matched) matches, \(result.cloudIDs.count) need iCloud, \(result.failedIDs.count) failed\(stopped ? ", stopped early" : "")")
        return result
    }

    private enum AssetCheck: Sendable {
        case checked([UUID: CGRect], needsDownload: Bool)
        case failed
    }

    private nonisolated static func check(
        _ candidate: ScanCandidate,
        identities: [UUID: [FaceEmbedding]],
        mode: ScanMode,
        model: MLModel,
        qos: DispatchQoS
    ) async -> AssetCheck {
        let asset = candidate.asset
        let library = PhotoLibraryService.shared

        switch mode {
        case .download:
            guard case .loaded(let image) = await library.load(asset, policy: .download(idle: 30, max: 180)) else {
                return .failed
            }
            let faces = await embedOffPool(image, model: model, qos: qos)
            return .checked(best(faces, for: candidate.friendIDs, identities: identities), needsDownload: false)

        case .local:
            switch await library.load(asset, policy: .localFull) {
            case .loaded(let image):
                let faces = await embedOffPool(image, model: model, qos: qos)
                return .checked(best(faces, for: candidate.friendIDs, identities: identities), needsDownload: false)
            case .failed:
                // Not an iCloud photo, yet it wouldn't load (timed out, busy):
                // let the download pass have a go, it has retries.
                return .checked([:], needsDownload: true)
            case .inCloud:
                // With "Optimize iPhone Storage" this is most of the library, and
                // the copy on the phone is a thumbnail too small to trust. Online,
                // just download it — a 1024px request pulls a derivative, not the
                // original, and takes a fraction of a second.
                if NetworkMonitor.shared.isOnline {
                    guard case .loaded(let image) = await library.load(asset, policy: .download(idle: 20, max: 60)) else {
                        return .checked([:], needsDownload: true)
                    }
                    let faces = await embedOffPool(image, model: model, qos: qos)
                    return .checked(best(faces, for: candidate.friendIDs, identities: identities), needsDownload: false)
                }
                // Offline: rule out what the on-phone copy can, queue the rest.
                guard case .loaded(let small) = await library.load(asset, policy: .localFast) else {
                    return .checked([:], needsDownload: true)
                }
                let pixels = small.cgImage.map { min($0.width, $0.height) } ?? 0
                guard pixels >= minTriageSide else {
                    logger.debug("iCloud photo \(asset.localIdentifier.prefix(8)): local copy \(pixels)px, needs download")
                    return .checked([:], needsDownload: true)
                }
                let faces = await embedOffPool(small, model: model, qos: qos)
                // No faces at all: nothing to download for.
                guard !faces.isEmpty else { return .checked([:], needsDownload: false) }
                let matches = best(faces, for: candidate.friendIDs, identities: identities)
                // Everyone found: done. Anyone not found might just be too small
                // in this copy — the full-size one decides.
                return .checked(matches, needsDownload: matches.count < candidate.friendIDs.count)
            }
        }
    }

    /// For each friend, the face that looks most like them, if any clears the bar.
    private nonisolated static func best(
        _ faces: [(embedding: FaceEmbedding, box: CGRect)],
        for friendIDs: [UUID],
        identities: [UUID: [FaceEmbedding]]
    ) -> [UUID: CGRect] {
        var matches: [UUID: CGRect] = [:]
        for friendID in friendIDs {
            guard let identity = identities[friendID], !identity.isEmpty else { continue }
            var bestSim = matchThreshold
            for (embedding, box) in faces {
                let sim = identity.map { cosine($0, embedding) }.max() ?? 0
                if sim >= bestSim {
                    bestSim = sim
                    matches[friendID] = box
                }
            }
        }
        return matches
    }

    /// Rebuilds a friend's identity from photos they're already known to be in:
    /// in each one, the embedded face sitting where the stored box says the friend
    /// is. Used once for friends saved before identities were persisted.
    func embedKnownFaces(_ known: [(asset: PHAsset, box: CGRect)], limit: Int = 3) async -> [FaceEmbedding] {
        let model = mlModel
        var identity: [FaceEmbedding] = []
        for (asset, box) in known {
            guard identity.count < limit, !Task.isCancelled else { break }
            let faces = await Self.embedFacesInAsset(asset, model: model)
            let best = faces.max { Self.overlap($0.box, box) < Self.overlap($1.box, box) }
            if let best, Self.overlap(best.box, box) > 0.5 {
                identity.append(best.embedding)
            }
        }
        return identity
    }

    /// Intersection-over-union of two normalized boxes.
    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull else { return 0 }
        let interArea = inter.width * inter.height
        let union = a.width * a.height + b.width * b.height - interArea
        return union > 0 ? interArea / union : 0
    }

    // MARK: Cover-photo verification
    //
    // Cheap presence-only check (no embedding) — used to confirm a generated cutout
    // still shows a real, detectable face before committing it as a friend's cover
    // photo, whether chosen automatically at creation or manually re-picked later.
    static func hasDetectableFace(in image: UIImage) -> Bool {
        guard let cgImage = normalizeOrientation(image).cgImage else { return false }
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        guard (try? handler.perform([request])) != nil else { return false }
        return !(request.results ?? []).isEmpty
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
        case modelNotFound
        var errorDescription: String? {
            switch self {
            case .modelNotFound: return "MobileFaceNet model not found in app bundle."
            }
        }
    }
}
