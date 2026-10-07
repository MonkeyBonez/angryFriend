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
nonisolated struct FaceTemplate: Sendable {
    let mean: FaceEmbedding

    init?(faces: [FaceEmbedding]) {
        guard let mean = FaceEmbedding.mean(of: faces) else { return nil }
        self.mean = mean
    }

    func similarity(to face: FaceEmbedding) -> Float {
        mean.cosineSimilarity(to: face)
    }
}
