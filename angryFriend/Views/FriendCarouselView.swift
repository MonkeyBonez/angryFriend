import SwiftUI
import UIKit
import SwiftData

/// Picking several friends for one round: who's checked, and what a tap does.
struct FriendSelection {
    var selected: Set<UUID>
    var onToggle: (Friend) -> Void
}

/// The suspect line-up. Each friend is a die-cut sticker: white border, ink ring,
/// hard shadow, leaning at a fixed angle so the row looks slapped together.
/// With a `selection`, tapping checks friends instead of playing them.
struct FriendCarouselView: View {
    let friends: [Friend]
    let onSelect: (Friend) -> Void
    let onHold: (Friend) -> Void
    let onEdit: (Friend) -> Void
    let onAddNew: () -> Void
    let onDemo: () -> Void
    var selection: FriendSelection? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 16) {
                AddStickerButton(isEnabled: selection == nil, action: onAddNew)
                    .popIn(delay: 0.05)

                ForEach(Array(friends.enumerated()), id: \.element.id) { index, friend in
                    FriendSticker(
                        friend: friend,
                        index: index,
                        onSelect: { onSelect(friend) },
                        onHold: { onHold(friend) },
                        onEdit: { onEdit(friend) },
                        selecting: selection != nil,
                        isSelected: selection?.selected.contains(friend.id) ?? false,
                        onToggle: { selection?.onToggle(friend) }
                    )
                    .popIn(delay: 0.1 + Double(index) * 0.06)
                }

                // The emoji pal stays in the line-up so a practice round is always
                // one tap away — except while picking suspects, where it can't be one.
                if selection == nil {
                    EmojiPalSticker(index: friends.count, action: onDemo)
                        .popIn(delay: 0.1 + Double(friends.count) * 0.06)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selection == nil)
            .padding(.horizontal, 28)
            .padding(.vertical, 10)
        }
        .scrollClipDisabled()
    }
}

// MARK: - One friend

private struct FriendSticker: View {
    let friend: Friend
    let index: Int
    let onSelect: () -> Void
    let onHold: () -> Void
    let onEdit: () -> Void
    var selecting = false
    var isSelected = false
    var onToggle: () -> Void = {}

    @State private var punch = false

    private let size: CGFloat = 78

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let sticker = UIImage(data: friend.stickerData) {
                        Image(uiImage: sticker)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "person.fill.questionmark")
                            .font(.system(size: size * 0.4, weight: .bold))
                            .foregroundStyle(StickerTheme.ink.opacity(0.5))
                    }
                }
                .frame(width: size, height: size)
                .background(StickerTheme.tile(index))
                .clipShape(Circle())
                .overlay(Circle().stroke(.white, lineWidth: 3.5))
                .overlay(Circle().stroke(StickerTheme.ink, lineWidth: checked ? 4 : 2).padding(-3.5))
                .hardShadow(StickerTheme.ink.opacity(0.35), x: 3, y: 4)
                .rotationEffect(.degrees(StickerTheme.lean(index)))
                .scaleEffect(punch ? 0.86 : (checked ? 1.06 : 1))
                .contentShape(Circle())
                .onTapGesture {
                    if selecting {
                        Haptics.flick()
                        onToggle()
                        return
                    }
                    Haptics.peel()
                    withAnimation(.spring(response: 0.16, dampingFraction: 0.5)) { punch = true }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.5).delay(0.12)) { punch = false }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { onSelect() }
                }
                .onLongPressGesture(minimumDuration: 0.4) {
                    guard !selecting else { return }
                    Haptics.press()
                    onHold()
                }

                if selecting {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(StickerTheme.mint, in: Circle())
                            .overlay(Circle().stroke(StickerTheme.ink, lineWidth: 2))
                            .offset(x: 5, y: -4)
                            .transition(.scale(scale: 0.2).combined(with: .opacity))
                            .allowsHitTesting(false)
                    }
                } else {
                    Button {
                        Haptics.peel()
                        onEdit()
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(StickerTheme.blue, in: Circle())
                            .overlay(Circle().stroke(StickerTheme.ink, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 5, y: -4)
                    .accessibilityLabel("Edit \(displayName)")
                    .transition(.opacity)
                }
            }

            TapeLabel(text: displayName, tilt: StickerTheme.lean(index + 3),
                      background: checked ? StickerTheme.ink : .white,
                      foreground: checked ? .white : StickerTheme.ink)
        }
        .frame(width: size + 8)
        .opacity(selecting && !isSelected ? 0.45 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.65), value: isSelected)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selecting)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(checked ? [.isSelected] : [])
        .accessibilityHint(selecting
            ? (isSelected ? "Tap to leave them out" : "Tap to add them to the round")
            : "Tap to play, press and hold to open their album")
    }

    private var checked: Bool { selecting && isSelected }

    private var displayName: String {
        friend.name.isEmpty ? "Friend" : friend.name
    }
}

// MARK: - Emoji pal

/// The stand-in friend: tap to deal a practice round of emoji faces. Dressed like
/// a real friend sticker so it reads as one of the suspects, with a blue tape
/// label so nobody mistakes it for someone they added.
struct EmojiPalSticker: View {
    var index: Int = 0
    var size: CGFloat = 78
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var punch = false

    var body: some View {
        VStack(spacing: 8) {
            Text(EmojiDeck.mascot)
                .font(.system(size: size * 0.56))
                .frame(width: size, height: size)
                .background(StickerTheme.tile(index))
                .clipShape(Circle())
                .overlay(Circle().stroke(.white, lineWidth: 3.5))
                .overlay(Circle().stroke(StickerTheme.ink, lineWidth: 2).padding(-3.5))
                .hardShadow(StickerTheme.ink.opacity(0.35), x: 3, y: 4)
                .rotationEffect(.degrees(StickerTheme.lean(index)))
                .scaleEffect(punch ? 0.86 : 1)
                .contentShape(Circle())
                .onTapGesture {
                    guard isEnabled else { return }
                    Haptics.peel()
                    withAnimation(.spring(response: 0.16, dampingFraction: 0.5)) { punch = true }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.5).delay(0.12)) { punch = false }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { action() }
                }

            TapeLabel(text: "Emoji Pal", tilt: StickerTheme.lean(index + 3),
                      background: StickerTheme.blue, foreground: .white)
        }
        .frame(width: size + 8)
        .opacity(isEnabled ? 1 : 0.4)
        .animation(.easeOut(duration: 0.2), value: isEnabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Emoji Pal")
        .accessibilityHint("Tap to play a practice round with emoji faces")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Add new

private struct AddStickerButton: View {
    var isEnabled: Bool = true
    let action: () -> Void
    private let size: CGFloat = 78

    var body: some View {
        Button {
            Haptics.press()
            action()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 28, weight: .black))
                    .foregroundStyle(StickerTheme.ink.opacity(0.6))
                    .frame(width: size, height: size)
                    .background(Color.white.opacity(0.55), in: Circle())
                    .overlay(
                        Circle().strokeBorder(
                            StickerTheme.ink.opacity(0.65),
                            style: StrokeStyle(lineWidth: 2.5, dash: [7, 6])
                        )
                    )

                TapeLabel(text: "New", tilt: 2, background: StickerTheme.sun)
            }
            .frame(width: size + 8)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .animation(.easeOut(duration: 0.2), value: isEnabled)
        .accessibilityLabel("Add a new friend")
    }
}
