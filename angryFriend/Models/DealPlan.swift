import Foundation

/// How a round's cards are shared out when several friends play at once.
nonisolated enum DealPlan {
    /// Cards per friend. More friends than cards: that many friends at random,
    /// one each. Otherwise an even split with the remainder to random friends,
    /// each capped at the photos they have, and any shortfall moved one card at
    /// a time onto friends with photos to spare. The total never exceeds
    /// `cardCount` (it is less only when everyone together has fewer photos).
    static func shares(cardCount: Int, available: [UUID: Int]) -> [UUID: Int] {
        let ids = available.filter { $0.value > 0 }.map(\.key)
        guard cardCount > 0, !ids.isEmpty else { return [:] }

        if ids.count > cardCount {
            return Dictionary(uniqueKeysWithValues: ids.shuffled().prefix(cardCount).map { ($0, 1) })
        }

        let base = cardCount / ids.count
        let extra = Set(ids.shuffled().prefix(cardCount % ids.count))
        var shares: [UUID: Int] = [:]
        var deficit = 0
        for id in ids {
            let want = base + (extra.contains(id) ? 1 : 0)
            let have = available[id] ?? 0
            shares[id] = min(want, have)
            deficit += max(0, want - have)
        }

        while deficit > 0 {
            let spare = ids.shuffled().filter { shares[$0, default: 0] < available[$0, default: 0] }
            guard !spare.isEmpty else { break }
            for id in spare where deficit > 0 {
                shares[id, default: 0] += 1
                deficit -= 1
            }
        }
        return shares
    }

    /// The deal bar's line: "12 cards → 4 each", "12 cards → 2 or 3 each",
    /// "6 cards · 8 suspects → 6 random suspects, 1 each".
    static func splitLine(cardCount: Int, friendCount: Int) -> String {
        guard friendCount > 0 else { return "\(cardCount) cards" }
        if friendCount > cardCount {
            return "\(cardCount) cards · \(friendCount) suspects → \(cardCount) random suspects, 1 each"
        }
        let base = cardCount / friendCount
        if cardCount % friendCount == 0 {
            return "\(cardCount) cards → \(base) each"
        }
        return "\(cardCount) cards → \(base) or \(base + 1) each"
    }

    /// "Ames", "Ames and Big V", "Ames, Big V and A-Train".
    static func names(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }
}
