struct FaceEmbedding: Sendable {
    static let dimension = 512

    let vector: [Float]  // 512-dim, L2-normalized

    func cosineSimilarity(to other: FaceEmbedding) -> Float {
        // L2-normalized vectors: cosine similarity = dot product
        zip(vector, other.vector).reduce(0) { $0 + $1.0 * $1.1 }
    }

    /// The normalised average of `faces` — what a person looks like across
    /// several photos, with each photo's noise averaged away. Nil for no faces.
    static func mean(of faces: [FaceEmbedding]) -> FaceEmbedding? {
        guard let first = faces.first else { return nil }
        var sum = [Float](repeating: 0, count: first.vector.count)
        for face in faces where face.vector.count == sum.count {
            for i in sum.indices { sum[i] += face.vector[i] }
        }
        let norm = sum.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return nil }
        return FaceEmbedding(vector: sum.map { $0 / norm })
    }
}

/// What a friend looks like, for matching: the mean of their stored faces.
/// Scoring a face against the mean beats "best of a few single faces" — a
/// single face carries its own lighting and angle, which a stranger can share.
/// `negatives` are faces the user said aren't this friend ("Not them").
nonisolated struct FaceTemplate: Sendable {
    let mean: FaceEmbedding
    let negatives: [FaceEmbedding]

    init?(faces: [FaceEmbedding], negatives: [FaceEmbedding] = []) {
        guard let mean = FaceEmbedding.mean(of: faces) else { return nil }
        self.mean = mean
        self.negatives = negatives
    }

    func similarity(to face: FaceEmbedding) -> Float {
        mean.cosineSimilarity(to: face)
    }

    /// The face looks more like someone the user said isn't this friend than
    /// like the friend. One "Not them" on a stranger also turns away their
    /// other photos: same-person faces sit far closer to each other (0.6–0.9)
    /// than a stranger does to the friend (≈0.3).
    func rejects(_ face: FaceEmbedding) -> Bool {
        let own = similarity(to: face)
        return negatives.contains { $0.cosineSimilarity(to: face) > own }
    }
}
