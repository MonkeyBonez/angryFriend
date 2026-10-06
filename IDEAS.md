# Ideas

Things we want to build next, with enough context to pick any one up cold.
Not ordered by priority.

---


## Onboarding / how-to-play screen

A first-run screen covering the two things people won't guess: how the game is
played, and how to add friends well.

**Why:** Two rules aren't taught anywhere that works — that you pass the phone
after every tap (no longer shown at all), and that picking from the People album
in Photos gives much better results (a small caption under the add button). Both
are load-bearing, and a caption is not where someone looks before their first game.

**Where to start:** New view built from `Design/StickerKit.swift` primitives, shown
from `ContentView` when no friends exist and a "seen onboarding" flag is unset.
Use emoji to illustrate the rules so it doesn't need custom art. Pairs naturally
with the Emoji Pal demo round (`EmojiDeck`, `AppState.startDemoRound`) — the last
onboarding step could *be* the demo round.

---


## Reskin alerts and exit modals

Replace the system alerts and confirmation dialogs with sticker-styled ones.

**Why:** Every custom surface is yellow, outlined and hard-shadowed, and then a
stock grey iOS alert slides up and breaks the spell — most visibly on the exit
confirmation, which is the one modal people hit mid-game.

**Where to start:** Build one reusable sticker modal (dimmed ink scrim, white card
with `stickerCard()`, `StickerButtonStyle` actions) and replace these call sites:

- `GameView` — leave-game confirmation
- `FriendDetailView` — delete-friend confirmation
- `FriendAlbumView` — remove-photos confirmation, plus the add-photos and
  cover-photo alerts
- `HomeView` — the "Can't Start Game" too-few-photos alert

Worth keeping the native one for anything genuinely destructive if the custom
version ends up feeling too easy to dismiss by accident.

---

## Multicolor friend picker

Give each friend in the home carousel a colored tile backing so the picker reads
as colorfully as the game grid.

**Why:** The game screen is the most alive part of the app, and the home carousel
is comparatively muted — the same cutouts look better on the cards than they do
in the picker.

**Where to start:** `FriendCarouselView` already backs each sticker with
`StickerTheme.tile(index)` behind a circular crop. Try the fuller card treatment
instead — rounded square, white die-cut border, ink outline, per-index lean —
so a friend in the picker looks like the same object they become in the grid.

Watch out: tile color is currently keyed to carousel *position*, so a friend's
color changes when the list reorders. If the color is going to be this prominent,
derive it from something stable like the friend's `id` instead.

---

## Check whether videos get through the photo picker

Videos show up inside People collections in the picker even though it is set to
images only.

**Why:** Anything that isn't a photo is dropped after picking, so a selection that
includes videos can fall under the game size and trigger the "You picked N
photos" alert for no reason the user can see.

**Where to start:** `MultiImagePicker` in `HomeView.swift`. The filter was changed
to `.all(of: [.images, .not(.videos)])` on 2026-10-05 but not verified on a device
with a People album. Confirm videos no longer appear; if they still do, tell the
user how many were skipped instead of silently dropping them. Also check Live
Photos are still selectable.

---

## Keep syncing new photos, and show the user it's happening

The rescan only runs when a friend is tapped to play, and the only sign of it is
the AUTO-ADD NEW PICS switch on the home screen.

**Why:** Someone who hasn't played a friend in months gets no new photos until
they do, and nobody can tell whether a scan ran, is running, or found anything.

**Where to start:** `Services/FriendRescanner.swift` exposes `phase` and
`friendID` already. Open questions: scan every friend on app open rather than one
on tap; show progress or a "3 new photos" badge on the friend's sticker in
`FriendCarouselView`; where the on/off switch should live and how it explains
itself; what to say when access is limited to selected photos.
