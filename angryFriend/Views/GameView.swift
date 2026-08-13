import SwiftUI

struct GameView: View {
    @Environment(AppState.self) private var appState
    @State private var showExitConfirm = false
    @State private var flash = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var cardCount: Int { appState.gameModel.cards.count }

    private var columnCount: Int {
        max(2, Int(Double(cardCount).squareRoot().rounded()))
    }

    private var spacing: CGFloat { columnCount >= 4 ? 8 : 11 }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnCount)
    }

    private var safeCount: Int { appState.gameModel.tappedIndices.count }
    private var leftCount: Int { cardCount - safeCount }

    var body: some View {
        ZStack {
            StickerTheme.sun.ignoresSafeArea()
            ConfettiSheet(count: 18, opacity: 0.35, seed: 41).ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 16)
                    .padding(.top, 6)

                Text("don't pick the angry one 👀")
                    .font(.sticker(14.5, .heavy))
                    .foregroundStyle(StickerTheme.ink)
                    .padding(.top, 10)

                Spacer(minLength: 8)

                LazyVGrid(columns: columns, spacing: spacing) {
                    ForEach(Array(appState.gameModel.cards.enumerated()), id: \.element.id) { index, card in
                        GameCardView(card: card, cardIndex: index)
                            .popIn(delay: Double(index) * 0.035, from: 0.4, tilt: -10)
                    }
                }
                .padding(.horizontal, 16)

                Spacer(minLength: 8)

                Text("pass the phone after every tap")
                    .font(.sticker(11, .medium))
                    .foregroundStyle(StickerTheme.ink.opacity(0.6))
                    .padding(.bottom, 10)
            }

            // The whole room flashes when the angry card turns up.
            if flash {
                StickerTheme.flame
                    .opacity(0.55)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .onAppear { Haptics.warmUp() }
        .onChange(of: appState.gameModel.gameOver) { _, isOver in
            guard isOver, !reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.08)) { flash = true }
            withAnimation(.easeIn(duration: 0.45).delay(0.1)) { flash = false }
        }
        .confirmationDialog(
            "Leave this game?",
            isPresented: $showExitConfirm,
            titleVisibility: .visible
        ) {
            Button("Leave Game", role: .destructive, action: exitToHome)
            Button("Keep Playing", role: .cancel) {}
        } message: {
            Text("This round will be lost and you'll go back to the main menu.")
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                Haptics.press()
                showExitConfirm = true
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(StickerCircleButtonStyle(diameter: 32))
            .accessibilityLabel("Leave game")

            Spacer()

            HStack(spacing: 6) {
                Text("\(safeCount) SAFE")
                    .foregroundStyle(StickerTheme.mint)
                Text("·")
                    .foregroundStyle(StickerTheme.sun.opacity(0.5))
                Text("\(leftCount) LEFT")
                    .foregroundStyle(StickerTheme.sun)
            }
            .font(.sticker(11.5, .black))
            .contentTransition(.numericText())
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(StickerTheme.ink, in: Capsule())
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: safeCount)

            Spacer()

            // Balances the close button so the score pill stays centred.
            Color.clear.frame(width: 32, height: 32)
        }
    }

    private func exitToHome() {
        appState.gameModel.reset()
        appState.pendingPhotoIDs = []
        appState.usedPhotoIDs = []
        appState.currentFriend = nil
        appState.screen = .home
    }
}
