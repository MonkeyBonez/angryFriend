import SwiftUI
import UIKit

/// A friend's sticker, small: the carousel circle scaled down.
struct MiniSticker: View {
    let friend: Friend
    var size: CGFloat = 28
    var index: Int = 0

    var body: some View {
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
        .overlay(Circle().stroke(.white, lineWidth: max(1.5, size * 0.06)))
        .overlay(Circle().stroke(StickerTheme.ink, lineWidth: 1.5).padding(-max(1.5, size * 0.06)))
    }
}

/// Several friends' stickers fanned over each other, with "+N" past `maxShown`.
struct MiniStickerFan: View {
    let friends: [Friend]
    var size: CGFloat = 30
    var maxShown: Int = 4

    var body: some View {
        let shown = Array(friends.prefix(maxShown))
        HStack(spacing: -size * 0.4) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, friend in
                MiniSticker(friend: friend, size: size, index: i)
                    .rotationEffect(.degrees(StickerTheme.lean(i)))
                    .zIndex(Double(shown.count - i))
            }
            if friends.count > maxShown {
                TapeLabel(text: "+\(friends.count - maxShown)", tilt: 4, size: max(9, size * 0.32))
                    .padding(.leading, size * 0.5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(DealPlan.names(friends.map(\.displayName)))
    }
}

/// Who's in the round: each friend's mini sticker with their name on tape.
struct RosterRow: View {
    let friends: [Friend]
    var size: CGFloat = 26

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(friends.enumerated()), id: \.element.id) { i, friend in
                    HStack(spacing: 5) {
                        MiniSticker(friend: friend, size: size, index: i)
                        TapeLabel(text: friend.displayName, tilt: StickerTheme.lean(i + 3), size: 10)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playing with \(DealPlan.names(friends.map(\.displayName)))")
    }
}

extension Friend {
    /// The name to show: "Friend" when none was given.
    var displayName: String { name.isEmpty ? "Friend" : name }
}
