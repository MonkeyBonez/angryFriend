import SwiftUI
import UIKit

struct GameCardView: View {
    let card: GameCard
    let cardIndex: Int
    @Environment(AppState.self) private var appState

    @State private var shakeAmount: CGFloat = 0
    @State private var squish = false
    @State private var revealed = false

    private var corner: CGFloat { 14 }

    var body: some View {
        RoundedRectangle(cornerRadius: corner)
            .fill(.white)
            .aspectRatio(1, contentMode: .fit)
            .overlay { face.padding(5) }
            .overlay {
                RoundedRectangle(cornerRadius: corner)
                    .stroke(StickerTheme.ink, lineWidth: 2)
            }
            .overlay { if card.isTapped { verdictStamp } }
            .hardShadow(StickerTheme.ink.opacity(0.35), x: 3, y: 3)
            .rotationEffect(.degrees(card.isTapped ? 0 : StickerTheme.lean(cardIndex)))
            .scaleEffect(squish ? 0.9 : 1)
            .modifier(Shake(animatableData: shakeAmount))
            .contentShape(RoundedRectangle(cornerRadius: corner))
            .onTapGesture { handleTap() }
            .allowsHitTesting(!card.isTapped && !appState.gameModel.gameOver)
            .accessibilityLabel(card.isTapped ? (card.isAngry ? "Angry card" : "Safe card") : "Card \(cardIndex + 1)")
            .accessibilityAddTraits(.isButton)
    }

    private var face: some View {
        ZStack {
            StickerTheme.tile(cardIndex)
            Image(uiImage: card.image)
                .resizable()
                .scaledToFill()
        }
        .clipShape(RoundedRectangle(cornerRadius: corner - 5))
        .saturation(card.isTapped && !card.isAngry ? 0.35 : 1)
    }

    /// Green tick for a survivor, red flame for the one that ends the round.
    /// Inset to match the face so the white sticker border survives the reveal —
    /// a full-bleed wash would erase the card's silhouette.
    private var verdictStamp: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner - 5)
                .fill((card.isAngry ? StickerTheme.flame : StickerTheme.mint).opacity(0.85))
                .padding(5)

            Image(systemName: card.isAngry ? "flame.fill" : "checkmark")
                .font(.system(size: 34, weight: .black))
                .foregroundStyle(.white)
                .shadow(color: StickerTheme.ink, radius: 0, x: 2, y: 2)
                .scaleEffect(revealed ? 1 : 0.2)
                .rotationEffect(.degrees(revealed ? -8 : 30))
        }
        .transition(.opacity)
        .onAppear {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.5)) { revealed = true }
        }
    }

    private func handleTap() {
        let isAngry = appState.gameModel.cards[cardIndex].isAngry

        withAnimation(.spring(response: 0.16, dampingFraction: 0.5)) { squish = true }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.45).delay(0.1)) { squish = false }

        withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) {
            appState.gameModel.tap(index: cardIndex)
        }

        if isAngry {
            Haptics.boom()
            triggerShake()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
                appState.screen = .result
            }
        } else {
            Haptics.safe()
        }
    }

    private func triggerShake() {
        shakeAmount = 0
        withAnimation(.easeOut(duration: 0.6)) { shakeAmount = 1 }
    }
}
