import SwiftUI

enum TutorialMode: Equatable {
    case firstRun   // shown instead of the picker the first time someone adds a friend
    case replay     // opened from the "how?" link on the home screen
}

enum TutorialExit {
    case gotIt      // finished the last step — open the picker
    case skipped    // Skip button or dragged the card away
}

/// A white sticker card over the dimmed home screen that walks through adding a
/// friend from the People album. Drawn here rather than with a system sheet so the
/// scrim, outline and spring match the rest of the app.
struct AddFriendTutorialView: View {
    let mode: TutorialMode
    let onFinish: (TutorialExit) -> Void

    @State private var step = 0
    @State private var shown = false
    @State private var drag: CGFloat = 0
    @State private var liveCaption = ""

    private static let lastStep = 5          // 0 intro · 1–4 steps · 5 one more thing
    private static let numberedSteps = 4
    private var isLast: Bool { step == Self.lastStep }

    var body: some View {
        ZStack(alignment: .bottom) {
            StickerTheme.ink
                .opacity(shown ? 0.55 : 0)
                .ignoresSafeArea()

            card
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .offset(y: shown ? max(0, drag) : 700)
                .gesture(dragToDismiss)
        }
        .onAppear {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { shown = true }
        }
    }

    // MARK: - Card

    private var card: some View {
        VStack(spacing: 10) {
            TapeLabel(text: tape)

            // A fixed slot so step 4's changing caption never resizes the card.
            Text(caption)
                .font(.sticker(15, .heavy))
                .foregroundStyle(StickerTheme.ink)
                .multilineTextAlignment(.center)
                .frame(minHeight: 56)
                .frame(maxWidth: .infinity)
                .contentTransition(.opacity)

            picture
                .id(step)
                .transition(.scale(scale: 0.92).combined(with: .opacity))

            HStack(spacing: 10) {
                Button(step == 0 ? "Skip" : "Back") {
                    Haptics.press()
                    if step == 0 { finish(.skipped) } else { go(to: step - 1) }
                }
                .buttonStyle(StickerButtonStyle(background: .white, foreground: StickerTheme.ink, size: 15))

                Button(isLast ? "Got it" : "Next") {
                    Haptics.press()
                    if isLast { finish(.gotIt) } else { go(to: step + 1) }
                }
                .buttonStyle(StickerButtonStyle(background: StickerTheme.pink, size: 15))
            }
        }
        .padding(.top, 16)
        .padding([.horizontal, .bottom], 12)
        .stickerCard(cornerRadius: 22)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: step)
    }

    private var tape: String {
        switch step {
        case 0: return "BEFORE YOU PICK"
        case Self.lastStep: return "ONE MORE THING"
        default: return "STEP \(step) OF \(Self.numberedSteps)"
        }
    }

    @ViewBuilder
    private var picture: some View {
        switch step {
        case 0: IntroPicture()
        case 1: CollectionsPicture()
        case 2: PeoplePicture()
        case 3: FriendPicture()
        case 4: SelectPicture(caption: $liveCaption)
        default: KeepFindingPicture()
        }
    }

    private var caption: String {
        switch step {
        case 0: return "Best way to add a friend: use your People album."
        case 1: return "Tap “Collections” at the top."
        case 2: return "Scroll down and tap “People”."
        case 3: return "Tap your friend."
        case 4: return liveCaption.isEmpty ? "Tap the top-left photo." : liveCaption
        default: return "Don't worry about grabbing every photo."
        }
    }

    // MARK: - Actions

    private func go(to next: Int) {
        Haptics.flick()
        liveCaption = ""
        step = next
    }

    private func finish(_ exit: TutorialExit) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { shown = false }
        Task {
            try? await Task.sleep(for: .seconds(0.3))
            onFinish(exit)
        }
    }

    private var dragToDismiss: some Gesture {
        DragGesture()
            .onChanged { drag = $0.translation.height }
            .onEnded { value in
                if value.translation.height > 110 {
                    Haptics.flick()
                    finish(.skipped)
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { drag = 0 }
                }
            }
    }
}
