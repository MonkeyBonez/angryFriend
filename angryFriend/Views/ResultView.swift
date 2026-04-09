import SwiftUI

struct ResultView: View {
    @Environment(AppState.self) private var appState
    @State private var bouncing = false

    private var losingCard: GameCard? {
        guard let idx = appState.gameModel.losingIndex,
              idx < appState.gameModel.cards.count else { return nil }
        return appState.gameModel.cards[idx]
    }

    var body: some View {
        ZStack {
            Color.red.opacity(0.12).ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                Text("💥")
                    .font(.system(size: 80))
                    .scaleEffect(bouncing ? 1.2 : 1.0)
                    .animation(.spring(duration: 0.4).repeatCount(4, autoreverses: true), value: bouncing)

                Text("ANGRY FRIEND!")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.red)

                Text("You found the angry one. Take your penalty!")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                if let card = losingCard {
                    Image(uiImage: card.image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 180, height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(Color.red, lineWidth: 4)
                        )
                        .shadow(color: .red.opacity(0.5), radius: 12)
                }

                Spacer()

                VStack(spacing: 12) {
                    Button(action: playAgain) {
                        Text("Play Again")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.red)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }

                    Button(action: startOver) {
                        Text("Pick a Different Friend")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
            }
        }
        .onAppear { bouncing = true }
    }

    private func playAgain() {
        // Feature 2: Re-sample fresh cards from the match pool
        appState.screen = .scanning
    }

    private func startOver() {
        appState.gameModel.reset()
        appState.seedImages = []
        appState.matchPool = []
        appState.usedAssetIDs = []
        appState.currentFriend = nil
        appState.screen = .seedPicker
    }
}
