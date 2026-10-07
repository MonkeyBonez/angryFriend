#if DEBUG
import Photos
import SwiftData
import os

/// Launched with `-identityDiagnostic`: measures, on the real albums, how each
/// friend's stored identity relates to the other friends' identities, and how
/// every album photo scores against its own friend versus the others. Logs
/// only; changes nothing.
enum IdentityDiagnostic {
    private static let logger = Logger(subsystem: "com.angryFriend", category: "Diagnostic")

    private static func fmt(_ x: Float) -> String { String(format: "%.3f", x) }

    @MainActor
    static func runIfRequested(context: ModelContext) async {
        guard ProcessInfo.processInfo.arguments.contains("-identityDiagnostic") else { return }
        let friends = (try? context.fetch(FetchDescriptor<Friend>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        guard !friends.isEmpty else { logger.error("Diag: no friends"); return }
        guard let service = try? FaceMatchingService() else { logger.error("Diag: no model"); return }
        FriendRescanner.shared.beginHold()
        defer { FriendRescanner.shared.endHold() }

        let names = friends.map(\.name)
        let identities = friends.map(\.identity)
        var templates: [UUID: FaceTemplate] = [:]
        for friend in friends { if let template = friend.template { templates[friend.id] = template } }
        let thr = FaceMatchingService.matchThreshold
        let summary = friends.map { "\($0.name): album \($0.photoMatches.count), identity \($0.identity.count) faces, excluded \($0.excludedIDs.count)" }
        logger.info("Diag: \(friends.count) friends (threshold \(thr), margin \(FaceMatchingService.matchMargin)) — \(summary.joined(separator: " | "))")

        // 1. Stored identities against each other, and within themselves.
        for a in friends.indices {
            let own = identities[a]
            var within: [String] = []
            for i in own.indices { for j in own.indices where j > i { within.append(fmt(own[i].cosineSimilarity(to: own[j]))) } }
            logger.info("Diag identity \(names[a]): faces agree with each other at \(within.joined(separator: " "))")
            for b in friends.indices where b > a {
                var maxSim: Float = -1
                var detail: [String] = []
                for (i, ea) in identities[a].enumerated() {
                    for (j, eb) in identities[b].enumerated() {
                        let s = ea.cosineSimilarity(to: eb)
                        maxSim = max(maxSim, s)
                        if s >= 0.2 { detail.append("\(names[a])#\(i)~\(names[b])#\(j)=\(fmt(s))") }
                    }
                }
                let flag = maxSim >= thr ? " ← a stored face of one matches the other" : ""
                logger.info("Diag identity: \(names[a]) vs \(names[b]): max \(fmt(maxSim))\(flag) \(detail.joined(separator: " "))")
            }
        }

        // 2. Every album photo: the face at the stored box, against every identity.
        for (fi, friend) in friends.enumerated() {
            let matches = friend.photoMatches
            var assets: [String: PHAsset] = [:]
            PHAsset.fetchAssets(withLocalIdentifiers: matches.map(\.assetID), options: nil).enumerateObjects { asset, _, _ in
                assets[asset.localIdentifier] = asset
            }
            var jobs: [(index: Int, asset: PHAsset, box: CGRect, faceWidth: Int)] = []
            var missing = 0
            for (i, match) in matches.enumerated() {
                guard let asset = assets[match.assetID] else { missing += 1; continue }
                let scale = min(1.0, 1024.0 / Double(max(asset.pixelWidth, asset.pixelHeight, 1)))
                jobs.append((i, asset, match.faceBoundingBox, Int(match.faceBoundingBox.width * Double(asset.pixelWidth) * scale)))
            }
            var embeddings: [Int: FaceEmbedding?] = [:]
            await withTaskGroup(of: (Int, FaceEmbedding?).self) { group in
                var iterator = jobs.makeIterator()
                var running = 0
                while running < 3, let job = iterator.next() {
                    group.addTask { (job.index, await service.embedKnownFaces([(asset: job.asset, box: job.box)], limit: 1).first) }
                    running += 1
                }
                while running > 0, let (index, embedding) = await group.next() {
                    running -= 1
                    embeddings[index] = embedding
                    if let job = iterator.next() {
                        group.addTask { (job.index, await service.embedKnownFaces([(asset: job.asset, box: job.box)], limit: 1).first) }
                        running += 1
                    }
                }
            }
            var counts: [String: Int] = ["OK": 0, "CLOSE": 0, "WRONG": 0, "LOW": 0, "NOFACE": 0]
            var wrongIDs: [String] = []
            // Which stored identity face carries each album photo? A face that carries many
            // photos the other stored faces don't recognise at all is probably someone else.
            var support = [Int](repeating: 0, count: identities[fi].count)
            var weakSupport = [Int](repeating: 0, count: identities[fi].count)
            var weakIDs = [[String]](repeating: [], count: identities[fi].count)
            for job in jobs {
                let match = matches[job.index]
                let id8 = String(match.assetID.prefix(8))
                guard let embedding = embeddings[job.index] ?? nil else {
                    counts["NOFACE", default: 0] += 1
                    logger.info("Diag photo \(names[fi]) \(id8) face \(job.faceWidth)px → NOFACE")
                    continue
                }
                let ownEach = identities[fi].map { $0.cosineSimilarity(to: embedding) }
                let own = friends[fi].template?.similarity(to: embedding) ?? 0
                if let k = ownEach.indices.max(by: { ownEach[$0] < ownEach[$1] }) {
                    support[k] += 1
                    let rest = ownEach.enumerated().filter { $0.offset != k }.map(\.element).max() ?? 0
                    if rest < 0.2 { weakSupport[k] += 1; if weakIDs[k].count < 12 { weakIDs[k].append(id8) } }
                }
                var otherName = "-", otherSim: Float = -1
                for (gi, other) in friends.enumerated() where gi != fi {
                    let s = other.template?.similarity(to: embedding) ?? -1
                    if s > otherSim { otherSim = s; otherName = names[gi] }
                }
                let verdict: String
                switch FaceMatchingService.owner(of: embedding, among: templates) {
                case .some(let owner) where owner == friend.id: verdict = "OK"
                case .some: verdict = "WRONG"
                case .none: verdict = otherSim > own ? "WRONG" : (own < thr ? "LOW" : "CLOSE")
                }
                counts[verdict, default: 0] += 1
                if verdict == "WRONG" { wrongIDs.append(id8) }
                logger.info("Diag photo \(names[fi]) \(id8) face \(job.faceWidth)px own \(ownEach.map(fmt).joined(separator: "/")) other \(otherName) \(fmt(otherSim)) → \(verdict)")
            }
            let countText = counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            logger.info("Diag album \(names[fi]): \(matches.count) photos (\(missing) not in library) — \(countText); WRONG: \(wrongIDs.joined(separator: " "))")
            for k in support.indices {
                logger.info("Diag support \(names[fi]) face #\(k): carries \(support[k]) photos, \(weakSupport[k]) of them unrecognised (<0.2) by the other stored faces: \(weakIDs[k].joined(separator: " "))")
            }
        }
        logger.info("Diag done")
    }
}
#endif
