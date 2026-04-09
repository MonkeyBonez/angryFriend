import SwiftUI

struct GameView: View {
    @Environment(AppState.self) private var appState

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            VStack(spacing: 16) {
                // Header
                VStack(spacing: 4) {
                    Text("Find the Angry Friend")
                        .font(.title2.bold())
                    Text("Turn \(appState.gameModel.currentTurn) — tap a card")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 20)

                // Card grid
                LazyVGrid(columns: columns, spacing: 10) {
                    let cards = appState.gameModel.cards
                    ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                        GameCardView(card: card, cardIndex: index)
                    }
                }
                .padding(.horizontal, 16)
                .animation(.spring(duration: 0.3), value: appState.gameModel.tappedIndices)

                Spacer()

                Button(action: restartGame) {
                    Label("Restart", systemImage: "arrow.counterclockwise")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 20)
            }
        }
    }

    private func restartGame() {
        // Feature 2: Re-sample from the match pool for fresh cards
        appState.screen = .scanning
    }
}
