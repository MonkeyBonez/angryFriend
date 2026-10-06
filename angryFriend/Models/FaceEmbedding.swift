struct FaceEmbedding: Sendable {
    static let dimension = 512

    let vector: [Float]  // 512-dim, L2-normalized

    func cosineSimilarity(to other: FaceEmbedding) -> Float {
        // L2-normalized vectors: cosine similarity = dot product
        zip(vector, other.vector).reduce(0) { $0 + $1.0 * $1.1 }
    }
}
