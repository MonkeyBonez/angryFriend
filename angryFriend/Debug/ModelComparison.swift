#if DEBUG
import Photos
import SwiftData
import UIKit
import os

/// Debug launch switches.
enum DebugLaunch {
    /// A diagnostic is running: the background scan stays off so it neither
    /// competes for the phone nor changes albums while they're measured.
    static let scanSuspended = ProcessInfo.processInfo.arguments.contains("-compareModels")
        || ProcessInfo.processInfo.arguments.contains("-identityDiagnostic")

    /// `-keepAwake`: no auto-lock while the app is in front, so a long run
    /// (diagnostic, album tidy, library walk) isn't suspended by a dark screen.
    @MainActor
    static func applyKeepAwake() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-keepAwake") || scanSuspended {
            UIApplication.shared.isIdleTimerDisabled = true
        }
    }
}

/// `-compareModels`: every bundled face model, judged on the real albums.
///
/// Each album photo is loaded once and its friend's face aligned once; every
/// model embeds that same chip. Per model, each friend's identity is rebuilt
/// the way the album tidy does it (first 24 album photos → largest group → 10
/// most central faces), and every album photo is judged with `owner(of:)`:
/// kept, someone else's, or no one's. Changes nothing. Writes the chips and a
/// CSV to Documents/diag/compare for pulling off the phone.
enum ModelComparison {
    private static let logger = Logger(subsystem: "com.angryFriend", category: "Diagnostic")
    private static func fmt(_ x: Float) -> String { String(format: "%.3f", x) }

    private struct Photo {
        let friend: Int
        let id: String
        let faceWidth: Int
        var embeddings: [FaceEmbedding?]
    }

    @MainActor
    static func runIfRequested(context: ModelContext) async {
        guard ProcessInfo.processInfo.arguments.contains("-compareModels") else { return }
        FriendRescanner.shared.stop()
        let friends = (try? context.fetch(FetchDescriptor<Friend>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        let models = [FaceModel.mobileFaceNet, FaceModel.resNet50].filter(\.isBundled)
        let services = models.compactMap { try? FaceMatchingService(model: $0) }
        guard !friends.isEmpty, services.count == models.count, !models.isEmpty else {
            logger.error("Cmp: nothing to compare (\(friends.count) friends, \(models.count) models)")
            return
        }
        let names = friends.map(\.name)
        let modelNames = models.map(\.resource)
        logger.info("Cmp: \(friends.count) friends × \(models.count) models (\(modelNames.joined(separator: ", "))): \(friends.map { "\($0.name) \($0.photoMatches.count)" }.joined(separator: ", "))")

        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("diag/compare", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        for i in friends.indices {
            try? FileManager.default.createDirectory(at: dir.appendingPathComponent("f\(i)"), withIntermediateDirectories: true)
        }
        try? names.enumerated().map { "f\($0.offset)\t\($0.element)" }.joined(separator: "\n")
            .write(to: dir.appendingPathComponent("names.tsv"), atomically: true, encoding: .utf8)

        // 1. Embed every album photo's friend face with every model.
        var photos: [Photo] = []
        var noFace = [Int](repeating: 0, count: friends.count)
        var totalMs = [Double](repeating: 0, count: models.count)
        var timed = 0
        let started = Date()
        for (fi, friend) in friends.enumerated() {
            let matches = friend.photoMatches
            var assets: [String: PHAsset] = [:]
            PHAsset.fetchAssets(withLocalIdentifiers: matches.map(\.assetID), options: nil).enumerateObjects { asset, _, _ in
                assets[asset.localIdentifier] = asset
            }
            // Very large albums: the first 24 (the identity's source) plus an even sample, 600 in all.
            var indices = Array(matches.indices)
            // `-recentOnly`: the identity's source plus the newest 150 — what a scan just added.
            if ProcessInfo.processInfo.arguments.contains("-recentOnly") {
                indices = Array(Set(indices.prefix(24)).union(indices.suffix(150))).sorted()
            } else if indices.count > 800 {
                let rest = Array(indices.dropFirst(24))
                let step = Double(rest.count) / 576
                indices = Array(indices.prefix(24)) + (0..<576).map { rest[Int(Double($0) * step)] }
            }
            let jobs: [(index: Int, asset: PHAsset, box: CGRect)] = indices.compactMap { i in
                assets[matches[i].assetID].map { (i, $0, matches[i].faceBoundingBox) }
            }
            var byIndex: [Int: Photo] = [:]
            await withTaskGroup(of: (Int, (chip: CGImage, embeddings: [FaceEmbedding?], milliseconds: [Double])?).self) { group in
                var iterator = jobs.makeIterator()
                var running = 0
                func launch(_ job: (index: Int, asset: PHAsset, box: CGRect)) {
                    group.addTask { (job.index, await FaceMatchingService.debugEmbedKnownFace(job.asset, box: job.box, services: services)) }
                    running += 1
                }
                while running < 6, let job = iterator.next() { launch(job) }
                while running > 0, let (index, result) = await group.next() {
                    running -= 1
                    if let job = iterator.next() { launch(job) }
                    let match = matches[index]
                    guard let result else { noFace[fi] += 1; continue }
                    let id8 = String(match.assetID.prefix(8))
                    if let jpeg = UIImage(cgImage: result.chip).jpegData(compressionQuality: 0.85) {
                        try? jpeg.write(to: dir.appendingPathComponent("f\(fi)/\(id8).jpg"))
                    }
                    for m in models.indices { totalMs[m] += result.milliseconds[m] }
                    timed += 1
                    let asset = jobs.first { $0.index == index }?.asset
                    let scale = min(1.0, 1024.0 / Double(max(asset?.pixelWidth ?? 1, asset?.pixelHeight ?? 1, 1)))
                    let width = Int(match.faceBoundingBox.width * Double(asset?.pixelWidth ?? 0) * scale)
                    byIndex[index] = Photo(friend: fi, id: id8, faceWidth: width, embeddings: result.embeddings)
                }
            }
            photos += byIndex.keys.sorted().compactMap { byIndex[$0] }
            logger.info("Cmp: embedded \(names[fi]) — \(byIndex.count) of \(indices.count) checked (album \(matches.count), \(indices.count - jobs.count) gone from library, \(noFace[fi]) no face at the box); \(Int(Date().timeIntervalSince(started)))s so far")
        }
        let msText = models.indices.map { "\(modelNames[$0]) \(String(format: "%.1f", totalMs[$0] / Double(max(timed, 1)))) ms" }.joined(separator: ", ")
        logger.info("Cmp: embedding time per face — \(msText)")

        // 2. Per model: rebuild identities, judge every album photo.
        var csv = "friend\tid\tfaceWidth\tmodel\town\tbestOther\tbestOtherSim\tverdict\n"
        for (m, model) in models.enumerated() {
            var templates: [UUID: FaceTemplate] = [:]
            for (fi, friend) in friends.enumerated() {
                let sample = photos.filter { $0.friend == fi }.prefix(24).compactMap { $0.embeddings[m] }
                let identity = FaceMatchingService.representativeFaces(sample, threshold: model.clusterThreshold)
                if let template = FaceTemplate(faces: identity) { templates[friend.id] = template }
                let agree = identity.map { face in templates[friend.id]?.similarity(to: face) ?? 0 }
                logger.info("Cmp \(model.resource) identity \(names[fi]): \(identity.count) faces from \(sample.count); face-to-mean \(fmt(agree.min() ?? 0))–\(fmt(agree.max() ?? 0))")
            }
            var kept = [Int](repeating: 0, count: friends.count)
            var other = [Int](repeating: 0, count: friends.count)
            var none = [Int](repeating: 0, count: friends.count)
            var otherTo = [[String: Int]](repeating: [:], count: friends.count)
            for photo in photos {
                guard let face = photo.embeddings[m] else { continue }
                let friend = friends[photo.friend]
                let own = templates[friend.id]?.similarity(to: face) ?? 0
                var bestOther = "-", bestOtherSim: Float = -1
                for (gi, g) in friends.enumerated() where gi != photo.friend {
                    let s = templates[g.id]?.similarity(to: face) ?? -1
                    if s > bestOtherSim { bestOtherSim = s; bestOther = names[gi] }
                }
                let verdict: String
                switch FaceMatchingService.owner(of: face, among: templates, threshold: model.matchThreshold) {
                case .some(let owner) where owner == friend.id:
                    verdict = "kept"; kept[photo.friend] += 1
                case .some(let owner):
                    let ownerName = friends.first { $0.id == owner }?.name ?? "?"
                    verdict = "other:\(ownerName)"; other[photo.friend] += 1; otherTo[photo.friend][ownerName, default: 0] += 1
                case .none:
                    verdict = "none"; none[photo.friend] += 1
                }
                csv += "\(names[photo.friend])\t\(photo.id)\t\(photo.faceWidth)\t\(model.resource)\t\(fmt(own))\t\(bestOther)\t\(fmt(bestOtherSim))\t\(verdict)\n"
            }
            for fi in friends.indices {
                let to = otherTo[fi].map { "\($0.key) \($0.value)" }.joined(separator: ", ")
                logger.info("Cmp \(model.resource) album \(names[fi]): kept \(kept[fi]), someone else's \(other[fi])\(to.isEmpty ? "" : " (\(to))"), no one's \(none[fi]), no face \(noFace[fi])")
            }
        }
        try? csv.write(to: dir.appendingPathComponent("results.tsv"), atomically: true, encoding: .utf8)
        logger.info("Cmp done in \(Int(Date().timeIntervalSince(started)))s; wrote \(dir.path)")
    }
}
#endif
