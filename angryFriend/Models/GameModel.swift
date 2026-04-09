import SwiftUI
import UIKit
import Photos

struct GameCard: Identifiable {
    let id = UUID()
    let image: UIImage
    let isAngry: Bool
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

    func setup(from cards: [GameCard]) {
        self.cards = cards
        tappedIndices = []
        gameOver = false
        losingIndex = nil
        currentTurn = 1
    }

    func tap(index: Int) {
        guard !gameOver, !tappedIndices.contains(index) else { return }
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
