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
    let identity: [FaceEmbedding]      // up to `identityLimit` representative faces of the winning identity, most central first
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

/// A face-embedding model and the bars tuned for it. Embeddings from different
/// models can't be compared, so changing `current` means rebuilding every
/// friend's stored faces (bump `Friend.currentIdentityVersion`).
nonisolated struct FaceModel: Sendable, Equatable {
    let resource: String          // .mlpackage name in the app bundle
    /// A face goes to a friend only if it's at least this like their template.
    let matchThreshold: Float
    /// Linking bar when grouping faces by person (new friend's picks, rebuilt
    /// identities). Safe below the match bar because a face links to a group's
    /// mean, which can't chain through a look-alike the way best-member linking could.
    let clusterThreshold: Float

    // Tuned 2026-10-07 with scripts/faceeval on the PhotosOfFriends/Randoms sets
    // (mean template, one-person-per-face rule, 5-point alignment): the lowest
    // bars with no friend mixed up and no stranger added across ~1,900 stranger faces.
    static let mobileFaceNet = FaceModel(resource: "MobileFaceNet", matchThreshold: 0.32, clusterThreshold: 0.30)  // recall 96%
    static let resNet50 = FaceModel(resource: "FaceNetR50", matchThreshold: 0.28, clusterThreshold: 0.28)          // recall 98%

    /// ResNet50 since 2026-10-07: on the real albums it caught the same mix-ups
    /// as MobileFaceNet, kept more true photos, and never let another person
    /// into a rebuilt identity (MobileFaceNet did 2–7% of the time); 6.4 vs
    /// 3.2 ms a face on an iPhone 14 Pro, against ~150 ms to load the photo.
    static let current = resNet50

    var isBundled: Bool { Bundle.main.url(forResource: resource, withExtension: "mlmodelc") != nil }
}

// MARK: - Service

actor FaceMatchingService {

    nonisolated static var matchThreshold: Float { FaceModel.current.matchThreshold }
    nonisolated static var clusterThreshold: Float { FaceModel.current.clusterThreshold }
    /// A face goes to a friend only if it looks this much more like them than
    /// like anyone else the app knows. Closer than that, nobody gets it.
    static let matchMargin: Float = 0.05
    /// Faces narrower than this in the 1024 px working image aren't matched:
    /// too few pixels for a dependable embedding, and no use as a card anyway.
    nonisolated static let minFaceWidth: CGFloat = 48
    /// Stored faces per friend.
    static let identityLimit = 10

    private static let logger = Logger(subsystem: "com.angryFriend", category: "FaceMatching")

    private nonisolated let mlModel: MLModel
    nonisolated let faceModel: FaceModel

    init(model: FaceModel = .current) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        guard let modelURL = Bundle.main.url(forResource: model.resource, withExtension: "mlmodelc") else {
            throw MatchError.modelNotFound
        }
        self.mlModel = try MLModel(contentsOf: modelURL, configuration: config)
        self.faceModel = model
    }

    // MARK: Orientation normalization

    private nonisolated static func normalizeOrientation(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        return UIGraphicsImageRenderer(size: image.size).image { _ in image.draw(at: .zero) }
    }

    // MARK: - Aligned 112×112 chip (what the face model was trained on)
    //
    // Five landmarks — eye centres, nose tip, mouth corners — are mapped onto the
    // ArcFace template with a least-squares similarity transform, the way the
    // model's training faces were aligned. Eyes-only (2-point) alignment is the
    // fallback when a landmark region is missing: it fixes scale and rotation
    // but not where the face sits vertically. Measured 2026-10-07: 5-point lifts
    // recall from 94% to 97% at the same false-match rate.
    //
    // Vision landmark coords (normalizedPoints) are bbox-local, y-up, origin bottom-left.
    // toPixel() converts them to full-image CGImage pixel coords (y-down, origin top-left).

    /// ArcFace 112×112 template: image-left eye, image-right eye, nose tip,
    /// image-left mouth corner, image-right mouth corner.
    private static let arcFaceTemplate = [
        CGPoint(x: 38.2946, y: 51.6963), CGPoint(x: 73.5318, y: 51.5014), CGPoint(x: 56.0252, y: 71.7366),
        CGPoint(x: 41.5493, y: 92.3655), CGPoint(x: 70.7299, y: 92.2041)
    ]

    /// Least-squares similarity transform (scale, rotation, translation; no
    /// reflection) taking `src` onto `dst`. Umeyama's closed form for 2-D.
    private static func similarityTransform(from src: [CGPoint], to dst: [CGPoint]) -> CGAffineTransform? {
        guard src.count == dst.count, src.count >= 2 else { return nil }
        let n = CGFloat(src.count)
        let ms = CGPoint(x: src.map(\.x).reduce(0, +) / n, y: src.map(\.y).reduce(0, +) / n)
        let md = CGPoint(x: dst.map(\.x).reduce(0, +) / n, y: dst.map(\.y).reduce(0, +) / n)
        var varSrc: CGFloat = 0, a: CGFloat = 0, b: CGFloat = 0
        for (s, d) in zip(src, dst) {
            let sx = s.x - ms.x, sy = s.y - ms.y, dx = d.x - md.x, dy = d.y - md.y
            varSrc += sx * sx + sy * sy
            a += dx * sx + dy * sy
            b += dy * sx - dx * sy
        }
        guard varSrc > 1e-6 else { return nil }
        a /= varSrc
        b /= varSrc
        let tx = md.x - a * ms.x + b * ms.y
        let ty = md.y - b * ms.x - a * ms.y
        return CGAffineTransform(a: a, b: b, c: -b, d: a, tx: tx, ty: ty)
    }

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

        var transform = CGAffineTransform.identity
            .translatedBy(x: 55.91, y: 51.60)
            .scaledBy(x: scale, y: scale)
            .rotated(by: -angle)
            .translatedBy(x: -midX, y: -midY)
        if let noseTip = landmarks.noseCrest?.normalizedPoints.last,
           let lips = landmarks.outerLips?.normalizedPoints, lips.count >= 2 {
            let lipPx = lips.map(toPixel)
            let mouthA = lipPx.min { $0.x < $1.x }!
            let mouthB = lipPx.max { $0.x < $1.x }!
            if let fivePoint = similarityTransform(from: [eyeA, eyeB, toPixel(noseTip), mouthA, mouthB], to: arcFaceTemplate) {
                transform = fivePoint
            }
        }

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

        // Each converted model names its tensors differently (MobileFaceNet's
        // output is var_950, ResNet50's var_1312); both have one in, one out.
        let description = model.modelDescription
        guard let inputName = description.inputDescriptionsByName.keys.first,
              let outputName = description.outputDescriptionsByName.keys.first,
              let featureProvider = try? MLDictionaryFeatureProvider(dictionary: [
                  inputName: MLFeatureValue(pixelBuffer: pb)
              ]) else { return nil }

        guard let output = try? model.prediction(from: featureProvider),
              let arr = output.featureValue(for: outputName)?.multiArrayValue else { return nil }

        var vec = (0..<arr.count).map { Float(truncating: arr[$0]) }
        let norm = sqrt(vec.reduce(0) { $0 + $1 * $1 })

        guard norm > 0 else { return nil }
        vec = vec.map { $0 / norm }
        return FaceEmbedding(vector: vec)
    }

    // MARK: All-face embedding (identity discovery)

    private nonisolated static func embedAllFaces(
        in cgImage: CGImage,
        model: MLModel,
        minFaceWidth: CGFloat
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
                guard facePixelWidth >= minFaceWidth else { continue }
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
        qos: DispatchQoS,
        minFaceWidth: CGFloat = minFaceWidth
    ) async -> [(embedding: FaceEmbedding, box: CGRect)] {
        await withCheckedContinuation { cont in
            visionQueue.async(qos: qos, flags: .enforceQoS) {
                guard let cgImage = normalizeOrientation(image).cgImage else {
                    cont.resume(returning: [])
                    return
                }
                cont.resume(returning: embedAllFaces(in: cgImage, model: model, minFaceWidth: minFaceWidth))
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

    // MARK: - Grouping faces by person

    /// One person's faces, linked by similarity to the group's running mean.
    nonisolated struct FaceGroup {
        private(set) var members: [FaceEmbedding]
        private(set) var photos: Set<Int>
        private(set) var mean: FaceEmbedding

        init(_ face: FaceEmbedding, photo: Int) {
            members = [face]
            photos = [photo]
            mean = face
        }

        mutating func add(_ face: FaceEmbedding, photo: Int) {
            members.append(face)
            photos.insert(photo)
            mean = FaceEmbedding.mean(of: members) ?? mean
        }

        /// Members most like the group as a whole first.
        var mostCentral: [FaceEmbedding] {
            members.sorted { mean.cosineSimilarity(to: $0) > mean.cosineSimilarity(to: $1) }
        }
    }

    /// Groups faces by person. A face joins the group whose mean it is most
    /// like, if that clears `threshold`; otherwise it starts a group. Linking to
    /// the mean, not the closest member, is what stops two people merging
    /// through a face that happens to resemble both.
    nonisolated static func group(_ faces: [(embedding: FaceEmbedding, photo: Int)], threshold: Float) -> [FaceGroup] {
        var groups: [FaceGroup] = []
        for (embedding, photo) in faces {
            var bestIndex: Int? = nil
            var bestSim = threshold
            for (i, group) in groups.enumerated() {
                let sim = group.mean.cosineSimilarity(to: embedding)
                if sim >= bestSim {
                    bestSim = sim
                    bestIndex = i
                }
            }
            if let i = bestIndex {
                groups[i].add(embedding, photo: photo)
            } else {
                groups.append(FaceGroup(embedding, photo: photo))
            }
        }
        return groups
    }

    /// The faces that best stand for one person among `faces` — the largest
    /// group, most central first, up to `limit`. Someone else's face that
    /// slipped in lands in a smaller group and is left out.
    nonisolated static func representativeFaces(_ faces: [FaceEmbedding], limit: Int = identityLimit,
                                                threshold: Float = clusterThreshold) -> [FaceEmbedding] {
        let groups = group(faces.enumerated().map { (embedding: $1, photo: $0) }, threshold: threshold)
        guard let largest = groups.max(by: { $0.members.count < $1.members.count }) else { return [] }
        return Array(largest.mostCentral.prefix(limit))
    }

    /// Who, of everyone the app knows, a face belongs to: the friend it looks
    /// most like, if that clears the bar and beats the runner-up by the margin.
    /// Nil when it's nobody's, or too close to call.
    nonisolated static func owner(of face: FaceEmbedding, among templates: [UUID: FaceTemplate],
                                  threshold: Float = matchThreshold) -> UUID? {
        var top: (id: UUID, sim: Float)? = nil
        var second: Float = -1
        for (id, template) in templates {
            let sim = template.similarity(to: face)
            if let current = top, sim <= current.sim {
                second = max(second, sim)
            } else {
                second = max(second, top?.sim ?? -1)
                top = (id, sim)
            }
        }
        guard let top, top.sim >= threshold, top.sim - second >= matchMargin else { return nil }
        return top.id
    }

    // MARK: - Dominant identity discovery (the core of "pick photos yourself")
    //
    // Embeds every face in every provided photo, groups them by person, and
    // returns the person who recurs across the most distinct photos — i.e.
    // whoever the user actually meant when they picked this batch, even if
    // other people also appear in some of the shots. Runs across ALL provided
    // assets (no random sampling) so a photo that only has the friend in a
    // group shot still counts as evidence.
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

        // Group by person; rank groups by distinct photos.
        let clusters = Self.group(facesPerPhoto.flatMap { photo, faces in faces.map { (embedding: $0.embedding, photo: photo) } },
                                  threshold: Self.clusterThreshold)

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
            var bestSim = Self.clusterThreshold
            for (embedding, box) in faces {
                let sim = winner.mean.cosineSimilarity(to: embedding)
                if sim >= bestSim {
                    bestSim = sim
                    bestBox = box
                }
            }
            guard let box = bestBox else { continue }
            matches.append(FriendPhotoMatch(asset: assets[photo], faceBoundingBox: box, isSoloFace: faces.count == 1))
        }

        return IdentityDiscoveryResult(identity: Array(winner.mostCentral.prefix(Self.identityLimit)), matches: matches)
    }

    private nonisolated static func embedFacesInAsset(
        _ asset: PHAsset,
        model: MLModel,
        minFaceWidth: CGFloat = minFaceWidth
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
        return await embedOffPool(image, model: model, qos: .userInitiated, minFaceWidth: minFaceWidth)
    }

    // MARK: - Background scan (find saved friends in the library)
    //
    // Nothing to cluster: each photo is loaded once, its faces embedded once, and
    // every face given to whichever friend it looks most like — judged against
    // everyone the app knows, not just the friends this photo is being checked
    // for, so a face that is really someone else's never goes to a weaker match.
    // A photo whose original is only in iCloud is downloaded on the spot when
    // the phone is online. Offline, the copy already on the phone is checked
    // instead, and the photo queued for a download if that copy is too small to
    // trust or shows faces that didn't match.

    /// Shortest side a local iCloud stand-in must have before a "no match" on it
    /// is trusted. Small renditions still find faces, but a friend in the
    /// background of one is too few pixels to recognise.
    nonisolated static let minTriageSide = 480

    func findFriends(
        templates: [UUID: FaceTemplate],
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
                         await Self.check(candidate, templates: templates, mode: mode, model: model, qos: qos))
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
        templates: [UUID: FaceTemplate],
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
            return .checked(best(faces, for: candidate.friendIDs, templates: templates), needsDownload: false)

        case .local:
            switch await library.load(asset, policy: .localFull) {
            case .loaded(let image):
                let faces = await embedOffPool(image, model: model, qos: qos)
                return .checked(best(faces, for: candidate.friendIDs, templates: templates), needsDownload: false)
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
                    return .checked(best(faces, for: candidate.friendIDs, templates: templates), needsDownload: false)
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
                let matches = best(faces, for: candidate.friendIDs, templates: templates)
                // Everyone found: done. Anyone not found might just be too small
                // in this copy — the full-size one decides.
                return .checked(matches, needsDownload: matches.count < candidate.friendIDs.count)
            }
        }
    }

    /// Each face goes to the one friend it looks most like (see `owner`); a
    /// friend who gets several faces in one photo keeps the best. Only friends
    /// in `friendIDs` are reported — the others already have this photo.
    private nonisolated static func best(
        _ faces: [(embedding: FaceEmbedding, box: CGRect)],
        for friendIDs: [UUID],
        templates: [UUID: FaceTemplate]
    ) -> [UUID: CGRect] {
        var matches: [UUID: (sim: Float, box: CGRect)] = [:]
        for (embedding, box) in faces {
            guard let owner = owner(of: embedding, among: templates), friendIDs.contains(owner),
                  let template = templates[owner] else { continue }
            let sim = template.similarity(to: embedding)
            if let current = matches[owner], current.sim >= sim { continue }
            matches[owner] = (sim, box)
        }
        return matches.mapValues(\.box)
    }

    /// The faces of a friend in photos they're already known to be in: in each
    /// one, the embedded face sitting where the stored box says the friend is.
    /// Accepts faces down to 28 px — the box is known, it's not a search.
    func embedKnownFaces(_ known: [(asset: PHAsset, box: CGRect)], limit: Int = identityLimit) async -> [FaceEmbedding] {
        let model = mlModel
        var identity: [FaceEmbedding] = []
        for (asset, box) in known {
            guard identity.count < limit, !Task.isCancelled else { break }
            let faces = await Self.embedFacesInAsset(asset, model: model, minFaceWidth: 28)
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

    #if DEBUG
    /// Diagnostic: the face at `box` in `asset`, aligned once and embedded by
    /// each of `services`' models — so models can be compared on the same chip.
    nonisolated static func debugEmbedKnownFace(
        _ asset: PHAsset, box: CGRect, services: [FaceMatchingService]
    ) async -> (chip: CGImage, embeddings: [FaceEmbedding?], milliseconds: [Double])? {
        let targetSize = CGSize(width: 1024, height: 1024)
        var image = await PhotoLibraryService.shared.loadImage(for: asset, targetSize: targetSize, allowNetwork: false)
        if image == nil {
            image = await PhotoLibraryService.shared.loadImage(for: asset, targetSize: targetSize, allowNetwork: true, timeoutSeconds: 15)
        }
        guard let image else { return nil }
        let models = services.map(\.mlModel)
        return await withCheckedContinuation { cont in
            visionQueue.async(qos: .userInitiated) {
                let result: (CGImage, [FaceEmbedding?], [Double])? = autoreleasepool {
                    guard let cgImage = normalizeOrientation(image).cgImage else { return nil }
                    let req = VNDetectFaceLandmarksRequest()
                    guard (try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([req])) != nil,
                          let face = (req.results ?? []).max(by: { overlap($0.boundingBox, box) < overlap($1.boundingBox, box) }),
                          overlap(face.boundingBox, box) > 0.5 else { return nil }
                    let chip = alignedFaceChip(cgImage: cgImage, face: face) ?? cropToFace(cgImage: cgImage, box: face.boundingBox)
                    var embeddings: [FaceEmbedding?] = []
                    var times: [Double] = []
                    for model in models {
                        let start = CFAbsoluteTimeGetCurrent()
                        embeddings.append(extractEmbedding(from: chip, using: model))
                        times.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                    }
                    return (chip, embeddings, times)
                }
                cont.resume(returning: result.map { (chip: $0.0, embeddings: $0.1, milliseconds: $0.2) })
            }
        }
    }
    #endif

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
            case .modelNotFound: return "Face model not found in app bundle."
            }
        }
    }
}
