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

    var roster: [Friend] = []              // friends in the round being dealt/played; empty → new friend or demo
    var currentFriend: Friend? {           // single-friend view of the roster, for older call sites
        get { roster.first }
        set { roster = newValue.map { [$0] } ?? [] }
    }
    var resumeSelection: [UUID]? = nil     // "change the lineup": Home opens select mode with these checked
    var usedPhotoIDs: Set<String> = []     // photoMatches already used this session, so rounds vary

    var pendingPhotoIDs: [String] = []     // freshly picked photo identifiers, awaiting identity discovery

    var viewingFriend: Friend? = nil       // target for .friendDetail / .album, independent of gameplay
    var isPickingCoverPhoto: Bool = false  // true when .album was opened to re-pick viewingFriend's cover

    var isDemoRound: Bool = false          // the cards on the table are emoji, not a friend
    var pendingAddFriend: Bool = false     // Home should open the add-friend flow as soon as it appears

    let rescanner = FriendRescanner.shared // finds saved friends in the rest of the library, in the background
    let confetti = ConfettiClock()         // one clock so the background dots carry on across screens

    /// Deals a grid of emoji faces and goes straight to the table — there's
    /// nothing to identify or cut out, so `.processing` is skipped.
    func startDemoRound() {
        roster = []
        usedPhotoIDs = []
        pendingPhotoIDs = []
        isDemoRound = true
        gameModel.setup(from: EmojiDeck.deal(count: cardCount),
                        earliestAngryTap: EmojiDeck.safeOpeningTaps + 1)
        screen = .game
    }
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
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            // Keeps the sticker sheet behind every screen so cross-fades never
            // flash the system background between two yellow rooms.
            StickerTheme.sun.ignoresSafeArea()

            // Heat blast behind the result — the room is on fire.
            if appState.screen == .result {
                RadialGradient(
                    colors: [Color(red: 1.00, green: 0.612, blue: 0.420), StickerTheme.sun],
                    center: UnitPoint(x: 0.5, y: 0.38),
                    startRadius: 10,
                    endRadius: 420
                )
                .ignoresSafeArea()
                .transition(.opacity)
            }

            // One sheet of dots under every screen, outside the screen transition,
            // so they stay put while the rooms cross-fade over them. Which way they
            // move is decided here, by screen: lively everywhere, calm at the table.
            ConfettiSheet(motion: confettiMotion, opacity: confettiOpacity, clock: appState.confetti)
                .ignoresSafeArea()

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
        #if DEBUG
        .task { await ScanTestSeed.runIfRequested(context: angryFriendApp.container.mainContext) }
        .task { await IdentityDiagnostic.runIfRequested(context: angryFriendApp.container.mainContext) }
        .task {
            DebugLaunch.applyKeepAwake()
            await ModelComparison.runIfRequested(context: angryFriendApp.container.mainContext)
        }
        #endif
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Back from the background: carry on where the scan stopped, and
                // look at whatever was taken in the meantime.
                appState.rescanner.ensureRunning()
            case .background:
                appState.rescanner.appDidEnterBackground()
            default:
                break
            }
        }
        // The identity commits to the yellow sheet, so system chrome (alerts,
        // dialogs, the photo picker) stays light regardless of device setting.
        .preferredColorScheme(.light)
    }

    private var confettiMotion: ConfettiMotion {
        appState.screen == .game ? .calm : .lively
    }

    private var confettiOpacity: Double {
        switch appState.screen {
        case .home: return 0.55
        case .processing: return 0.45
        case .game: return 0.35
        case .result: return 0.4
        case .friendDetail: return 0.4
        case .album: return 0
        }
    }
}

#Preview {
    ContentView()
}
