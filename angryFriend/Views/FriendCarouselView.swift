import SwiftUI
import UIKit
import SwiftData

struct FriendCarouselView: View {
    let friends: [Friend]
    let onSelect: (Friend) -> Void
    let onAddNew: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                // "Add new" card
                Button(action: onAddNew) {
                    VStack(spacing: 6) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14)
                                .fill(Color(.systemGray5))
                                .frame(width: 90, height: 90)
                            Image(systemName: "plus")
                                .font(.system(size: 28))
                                .foregroundStyle(.secondary)
                        }
                        Text("New")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(friends) { friend in
                    Button {
                        onSelect(friend)
                    } label: {
                        VStack(spacing: 6) {
                            Group {
                                if let sticker = UIImage(data: friend.stickerData) {
                                    Image(uiImage: sticker)
                                        .resizable()
                                        .scaledToFill()
                                } else {
                                    Image(systemName: "person.crop.circle")
                                        .font(.system(size: 50))
                                        .foregroundStyle(.indigo)
                                }
                            }
                            .frame(width: 90, height: 90)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .shadow(radius: 3)

                            Text(friend.name)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 4)
        }
    }
}
