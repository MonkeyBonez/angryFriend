import SwiftUI
import UIKit
import SwiftData

struct FriendDetailView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let friend = appState.viewingFriend {
            FriendDetailContent(friend: friend)
        } else {
            // Shouldn't happen — no friend selected. Bail back to Home.
            Color.clear.onAppear { appState.screen = .home }
        }
    }
}

private struct FriendDetailContent: View {
    @Bindable var friend: Friend
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext

    @State private var showDeleteConfirm = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        ZStack {
            // Background sheet and dots come from ContentView.

            VStack(spacing: 0) {
                StickerTopBar(onLeading: finish)

                ScrollView {
                    VStack(spacing: 0) {
                        portrait
                            .padding(.top, 10)

                        Text("tap the sticker to change the cover")
                            .font(.sticker(10.5, .medium))
                            .foregroundStyle(StickerTheme.ink.opacity(0.65))
                            .padding(.top, 12)

                        nameField
                            .padding(.top, 20)

                        Button {
                            Haptics.peel()
                            viewAlbum()
                        } label: {
                            HStack(spacing: 5) {
                                Text("\(friend.photoMatches.count) photo\(friend.photoMatches.count == 1 ? "" : "s") in their album")
                                Image(systemName: "arrow.right")
                            }
                            .font(.sticker(12, .bold))
                            .foregroundStyle(StickerTheme.ink.opacity(0.75))
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 14)

                        Spacer(minLength: 30)

                        actions
                            .padding(.top, 28)
                            .padding(.bottom, 26)
                    }
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .onAppear { Haptics.warmUp() }
        .confirmationDialog(
            "Delete \(displayName)?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: deleteFriend)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes them and their album from Angry Friend. Photos stay in your library.")
        }
    }

    private var displayName: String {
        friend.name.isEmpty ? "this friend" : friend.name
    }

    // MARK: - Pieces

    private var portrait: some View {
        Button(action: pickNewCover) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let sticker = UIImage(data: friend.stickerData) {
                        Image(uiImage: sticker)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "person.fill.questionmark")
                            .font(.system(size: 56, weight: .bold))
                            .foregroundStyle(StickerTheme.ink.opacity(0.5))
                    }
                }
                .frame(width: 138, height: 138)
                .background(StickerTheme.tile(0))
                .clipShape(RoundedRectangle(cornerRadius: 26))
                .overlay(RoundedRectangle(cornerRadius: 26).stroke(.white, lineWidth: 4))
                .overlay(RoundedRectangle(cornerRadius: 28).stroke(StickerTheme.ink, lineWidth: 2.5).padding(-4))
                .hardShadow(StickerTheme.ink.opacity(0.35), x: 4, y: 5)

                Image(systemName: "pencil")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(StickerTheme.blue, in: Circle())
                    .overlay(Circle().stroke(StickerTheme.ink, lineWidth: 2.5))
                    .offset(x: 8, y: -8)
            }
            .rotationEffect(.degrees(-2))
        }
        .buttonStyle(.plain)
        .popIn(from: 0.6)
        .accessibilityLabel("Change cover photo")
    }

    private var nameField: some View {
        VStack(spacing: 7) {
            Text("NAME")
                .font(.sticker(10.5, .black))
                .foregroundStyle(StickerTheme.ink.opacity(0.6))

            TextField("Friend's name", text: $friend.name)
                .font(.sticker(20, .black))
                .foregroundStyle(StickerTheme.ink)
                .multilineTextAlignment(.center)
                .textFieldStyle(.plain)
                .focused($nameFocused)
                .submitLabel(.done)
                .onSubmit { nameFocused = false }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .frame(maxWidth: 250)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(nameFocused ? StickerTheme.pink : StickerTheme.ink, lineWidth: 2.5)
                )
                .hardShadow(StickerTheme.ink, x: 2.5, y: 2.5)
                .rotationEffect(.degrees(-1))
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: nameFocused)
                .onChange(of: friend.name) { _, _ in
                    try? modelContext.save()
                }
        }
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button(action: play) {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(StickerButtonStyle(background: StickerTheme.blue))

            Button(action: viewAlbum) {
                Label("View Album", systemImage: "photo.on.rectangle.angled")
            }
            .buttonStyle(StickerButtonStyle(background: .white, foreground: StickerTheme.ink))

            Button {
                Haptics.warn()
                showDeleteConfirm = true
            } label: {
                Text("delete friend")
                    .font(.sticker(12.5, .bold))
                    .foregroundStyle(StickerTheme.flame)
                    .underline()
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .padding(.horizontal, 30)
    }

    // MARK: - Actions

    private func finish() {
        try? modelContext.save()
        appState.viewingFriend = nil
        appState.isPickingCoverPhoto = false
        appState.screen = .home
    }

    private func play() {
        Haptics.press()
        appState.currentFriend = friend
        appState.usedPhotoIDs = []
        appState.viewingFriend = nil
        appState.isPickingCoverPhoto = false
        appState.rescanner.start(for: friend, context: modelContext)
        appState.screen = .processing
    }

    private func viewAlbum() {
        Haptics.press()
        appState.isPickingCoverPhoto = false
        appState.screen = .album
    }

    private func pickNewCover() {
        Haptics.peel()
        appState.isPickingCoverPhoto = true
        appState.screen = .album
    }

    private func deleteFriend() {
        if appState.currentFriend?.id == friend.id {
            appState.currentFriend = nil
        }
        if appState.rescanner.friendID == friend.id {
            appState.rescanner.cancel()
        }
        modelContext.delete(friend)
        try? modelContext.save()
        appState.viewingFriend = nil
        appState.isPickingCoverPhoto = false
        appState.screen = .home
    }
}
