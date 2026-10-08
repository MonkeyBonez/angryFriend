import SwiftUI
import UIKit
import Photos

struct GameCard: Identifiable {
    let id = UUID()
    let image: UIImage
    var isAngry: Bool
    var friendID: UUID? = nil   // whose face this card is; nil for the emoji demo
    var isTapped = false
}

@Observable
@MainActor
final class GameModel {
    var cards: [GameCard] = []
    var tappedIndices: Set<Int> = []
    var gameOver = false
    var losingIndex: Int? = nil
    var currentTurn = 1

    /// When set, no card is angry up front: the angry one is chosen at tap time,
    /// never before this tap number, and uniformly among whatever's left — so a
    /// demo round always lets a few people play before the reveal.
    private var earliestAngryTap: Int? = nil

    func setup(from cards: [GameCard], earliestAngryTap: Int? = nil) {
        self.cards = cards
        self.earliestAngryTap = earliestAngryTap
        tappedIndices = []
        gameOver = false
        losingIndex = nil
        currentTurn = 1
    }

    func tap(index: Int) {
        guard !gameOver, !tappedIndices.contains(index) else { return }
        if let earliestAngryTap {
            let tapNumber = tappedIndices.count + 1
            let remaining = cards.count - tappedIndices.count
            // 1-in-remaining keeps the odds the same as a pre-placed angry card;
            // the last card left is always it.
            cards[index].isAngry = tapNumber >= earliestAngryTap && Int.random(in: 0..<remaining) == 0
        }
        tappedIndices.insert(index)
        cards[index].isTapped = true
        if cards[index].isAngry {
            gameOver = true
            losingIndex = index
        } else {
            currentTurn += 1
        }
    }

    func reset() {
        cards = []
        tappedIndices = []
        gameOver = false
        losingIndex = nil
        currentTurn = 1
    }
}
