import SwiftUI
import UIKit

struct GameCardView: View {
    let card: GameCard
    let cardIndex: Int
    @Environment(AppState.self) private var appState

    @State private var isFlipped = false
    @State private var shakeOffset: CGFloat = 0

    var body: some View {
        ZStack {
            // Card face (always visible — all cards show the friend's face)
            Image(uiImage: card.image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 12))

            // Overlay after tap
            if card.isTapped {
                RoundedRectangle(cornerRadius: 12)
                    .fill(card.isAngry ? Color.red.opacity(0.75) : Color.green.opacity(0.75))
                    .transition(.opacity)

                Image(systemName: card.isAngry ? "flame.fill" : "checkmark.seal.fill")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.white)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
        .offset(x: shakeOffset)
        .onTapGesture { handleTap() }
        .disabled(card.isTapped || appState.gameModel.gameOver)
    }

    private func handleTap() {
        withAnimation(.spring(duration: 0.25)) {
            appState.gameModel.tap(index: cardIndex)
        }

        if card.isAngry || appState.gameModel.cards[cardIndex].isAngry {
            triggerShake()
            triggerHaptic(success: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                appState.screen = .result
            }
        } else {
            triggerHaptic(success: true)
        }
    }

    private func triggerShake() {
        let sequence: [CGFloat] = [-12, 12, -10, 10, -6, 6, 0]
        for (i, offset) in sequence.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.07) {
                withAnimation(.spring(duration: 0.06)) {
                    shakeOffset = offset
                }
            }
        }
    }

    private func triggerHaptic(success: Bool) {
        if success {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}
