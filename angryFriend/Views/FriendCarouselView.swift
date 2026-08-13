import SwiftUI
import UIKit
import SwiftData

/// The suspect line-up. Each friend is a die-cut sticker: white border, ink ring,
/// hard shadow, leaning at a fixed angle so the row looks slapped together.
struct FriendCarouselView: View {
    let friends: [Friend]
    let onSelect: (Friend) -> Void
    let onHold: (Friend) -> Void
    let onEdit: (Friend) -> Void
    let onAddNew: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 16) {
                AddStickerButton(action: onAddNew)
                    .popIn(delay: 0.05)

                ForEach(Array(friends.enumerated()), id: \.element.id) { index, friend in
                    FriendSticker(
                        friend: friend,
                        index: index,
                        onSelect: { onSelect(friend) },
                        onHold: { onHold(friend) },
                        onEdit: { onEdit(friend) }
                    )
                    .popIn(delay: 0.1 + Double(index) * 0.06)
                }
            }
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
                .overlay(Circle().stroke(StickerTheme.ink, lineWidth: 2).padding(-3.5))
                .hardShadow(StickerTheme.ink.opacity(0.35), x: 3, y: 4)
                .rotationEffect(.degrees(StickerTheme.lean(index)))
                .scaleEffect(punch ? 0.86 : 1)
                .contentShape(Circle())
                .onTapGesture {
                    Haptics.peel()
                    withAnimation(.spring(response: 0.16, dampingFraction: 0.5)) { punch = true }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.5).delay(0.12)) { punch = false }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { onSelect() }
                }
                .onLongPressGesture(minimumDuration: 0.4) {
                    Haptics.press()
                    onHold()
                }

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
            }

            TapeLabel(text: displayName, tilt: StickerTheme.lean(index + 3))
        }
        .frame(width: size + 8)
        .accessibilityElement(children: .contain)
        .accessibilityHint("Tap to play, press and hold to open their album")
    }

    private var displayName: String {
        friend.name.isEmpty ? "Friend" : friend.name
    }
}

// MARK: - Add new

private struct AddStickerButton: View {
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
        .accessibilityLabel("Add a new friend")
    }
}
