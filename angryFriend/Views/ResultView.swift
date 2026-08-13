import SwiftUI

struct ResultView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var boomScale: CGFloat = 0.2
    @State private var titleIn = false
    @State private var cardIn = false

    private var losingCard: GameCard? {
        guard let idx = appState.gameModel.losingIndex,
              idx < appState.gameModel.cards.count else { return nil }
        return appState.gameModel.cards[idx]
    }

    private var friendName: String {
        let name = appState.currentFriend?.name ?? ""
        return name.isEmpty ? "Your friend" : name
    }

    var body: some View {
        ZStack {
            // Heat blast behind the sticker sheet — the room is on fire.
            RadialGradient(
                colors: [
                    Color(red: 1.00, green: 0.612, blue: 0.420),
                    StickerTheme.sun,
                ],
                center: UnitPoint(x: 0.5, y: 0.38),
                startRadius: 10,
                endRadius: 420
            )
            .ignoresSafeArea()

            ConfettiSheet(count: 20, opacity: 0.4, seed: 59).ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 12)

                Text("💥")
                    .font(.system(size: 62))
                    .scaleEffect(boomScale)

                StickerText(text: "GOTCHA!", size: 40, fill: StickerTheme.pink, strokeWidth: 2.4)
                    .rotationEffect(.degrees(-2))
                    .scaleEffect(titleIn ? 1 : 2.4)
                    .opacity(titleIn ? 1 : 0)
                    .padding(.top, 4)

                Text("\(friendName) is FURIOUS. You lose this round.")
                    .font(.sticker(13.5, .bold))
                    .foregroundStyle(StickerTheme.ink)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
                    .padding(.top, 10)
                    .opacity(titleIn ? 1 : 0)

                if let card = losingCard {
                    Image(uiImage: card.image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 152, height: 152)
                        .background(StickerTheme.tile(1))
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .overlay(RoundedRectangle(cornerRadius: 20).stroke(StickerTheme.flame, lineWidth: 4))
                        .hardShadow(StickerTheme.ink, x: 5, y: 6)
                        .shadow(color: StickerTheme.flame.opacity(0.6), radius: 22)
                        .rotationEffect(.degrees(cardIn ? 4 : -14))
                        .scaleEffect(cardIn ? 1 : 0.5)
                        .opacity(cardIn ? 1 : 0)
                        .padding(.top, 22)
                }

                TapeLabel(text: "PENALTY: loser's rule — you decide 🍻", tilt: -2, size: 12)
                    .padding(.top, 18)
                    .opacity(cardIn ? 1 : 0)

                Spacer(minLength: 20)

                VStack(spacing: 14) {
                    Button(action: playAgain) {
                        Label("Play Again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(StickerButtonStyle(background: StickerTheme.flame))

                    Button(action: startOver) {
                        Text("pick a different friend")
                            .font(.sticker(12.5, .bold))
                            .foregroundStyle(StickerTheme.ink.opacity(0.75))
                            .underline()
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 24)
                .opacity(cardIn ? 1 : 0)
            }

            ConfettiBurst()
                .ignoresSafeArea()
        }
        .onAppear(perform: runEntrance)
    }

    private func runEntrance() {
        Haptics.sprinkle()

        guard !reduceMotion else {
            boomScale = 1
            titleIn = true
            cardIn = true
            return
        }

        withAnimation(.spring(response: 0.4, dampingFraction: 0.45)) { boomScale = 1.15 }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.5).delay(0.12)) { titleIn = true }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.55).delay(0.26)) { cardIn = true }

        // Settle into a slow heartbeat once the slam-in has landed.
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true).delay(0.5)) {
            boomScale = 0.92
        }
    }

    private func playAgain() {
        Haptics.press()
        appState.screen = .processing
    }

    private func startOver() {
        Haptics.press()
        appState.gameModel.reset()
        appState.pendingPhotoIDs = []
        appState.usedPhotoIDs = []
        appState.currentFriend = nil
        appState.screen = .home
    }
}
