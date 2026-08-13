# Angry Friend

A party game for iOS. Pick some photos of one friend, and the app works out who
the recurring person is, cuts them out of every shot, and deals the cutouts as a
grid of cards. One card is secretly angry. Take turns tapping — whoever finds it
takes the penalty.

## How it works

Everything runs on device. There's no public API for the People album in Photos,
so the app builds its own identity pipeline:

1. **Detect & embed** — Vision finds faces; a MobileFaceNet Core ML model
   (ArcFace, 512-dim) embeds each one.
2. **Cluster** — greedy max-linkage clustering over cosine similarity picks the
   identity appearing in the most distinct photos.
3. **Cut out** — `VNGenerateForegroundInstanceMaskRequest` masks only that
   person's instance, so nobody else ends up on a card.

Friends are saved with SwiftData and can be replayed without re-running the
matching step.

## Build

Open `angryFriend.xcodeproj` in Xcode 26 and run. Requires iOS 26 and a device
or simulator with photo library access. Set your own signing team before
building to a device.

## Layout

```
angryFriend/
├── Design/     StickerKit — palette, type, buttons, motion
├── Models/     Friend, FaceEmbedding, GameModel
├── Services/   photo loading, face matching, subject extraction, haptics
└── Views/      home, processing, game, result, friend detail, album
scripts/        Python tools for converting and testing the face model
archive/        pre-rebuild scan pipeline, kept for reference
```
