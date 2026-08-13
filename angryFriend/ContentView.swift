import SwiftUI
import UIKit
import Photos
import SwiftData

// MARK: - App-level state

@Observable
@MainActor
final class AppState {
    var screen: AppScreen = .home
    var gameModel = GameModel()
    var cardCount: Int = 12

    var currentFriend: Friend? = nil       // the friend currently being played
    var usedPhotoIDs: Set<String> = []     // photoMatches already used this session, so rounds vary

    var pendingPhotoIDs: [String] = []     // freshly picked photo identifiers, awaiting identity discovery

    var viewingFriend: Friend? = nil       // target for .friendDetail / .album, independent of gameplay
    var isPickingCoverPhoto: Bool = false  // true when .album was opened to re-pick viewingFriend's cover
}

enum AppScreen {
    case home
    case processing
    case game
    case result
    case friendDetail
    case album
}

// MARK: - Root view

struct ContentView: View {
    @State private var appState = AppState()

    var body: some View {
        ZStack {
            // Keeps the sticker sheet behind every screen so cross-fades never
            // flash the system background between two yellow rooms.
            StickerTheme.sun.ignoresSafeArea()

            Group {
                switch appState.screen {
                case .home:
                    HomeView()
                case .processing:
                    ProcessingView()
                case .game:
                    GameView()
                case .result:
                    ResultView()
                case .friendDetail:
                    FriendDetailView()
                case .album:
                    FriendAlbumView()
                }
            }
            .transition(.asymmetric(
                insertion: .scale(scale: 0.94).combined(with: .opacity),
                removal: .scale(scale: 1.04).combined(with: .opacity)
            ))
        }
        .environment(appState)
        .animation(.spring(response: 0.38, dampingFraction: 0.85), value: appState.screen)
        // The identity commits to the yellow sheet, so system chrome (alerts,
        // dialogs, the photo picker) stays light regardless of device setting.
        .preferredColorScheme(.light)
    }
}

#Preview {
    ContentView()
}
