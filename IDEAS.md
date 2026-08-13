# Ideas

Things we want to build next, with enough context to pick any one up cold.
Not ordered by priority.

---

## Emoji demo mode

Let someone play a full round without adding a friend first. If they have no
saved friends — or don't want to hand over their photo library yet — deal a grid
of emoji faces instead of cutouts. One is still secretly angry.

**Why:** Right now the app is a locked door. You cannot see the game until
you've picked photos and waited through identity discovery, which is a lot of
faith to ask for before you know whether the game is fun. A demo round is the
fastest possible answer to "what is this?", and it doubles as onboarding — you
learn the rules by playing rather than by reading them.

It also covers a real dead end: someone with no usable photos of any one person
currently gets an error and nothing to do.

**Where to start:** This was prototyped during the reskin and worked well. The
cards are ordinary `GameCard`s, so nothing in `GameModel` or `GameView` needs to
change — only the image source. Render each emoji into a `UIImage` with
`UIGraphicsImageRenderer`, drawing the emoji as an `NSString` at ~190pt into a
300×300 canvas, then build cards exactly the way `ProcessingView.setupGame` does.
Entry point would be a "Try a demo round" button on `HomeView`'s empty state,
skipping `.processing` entirely and going straight to `.game`.

Open question: after the demo ends, the result screen's "Play Again" should
probably nudge toward adding a real friend rather than dealing more emoji.

---

## Onboarding / how-to-play screen

A first-run screen covering the two things people won't guess: how the game is
played, and how to add friends well.

**Why:** Two rules currently live only as small captions in the UI — that you
pass the phone after every tap, and that picking from the People album in Photos
gives much better results. Both are load-bearing, and a caption under a button is
not where someone looks before their first game.

**Where to start:** New view built from `Design/StickerKit.swift` primitives, shown
from `ContentView` when no friends exist and a "seen onboarding" flag is unset.
Use emoji to illustrate the rules so it doesn't need custom art. Pairs naturally
with the emoji demo above — the last onboarding step could *be* the demo round.

---

## Animate the background confetti dots

Make the dots drift instead of sitting still.

**Why:** Everything else on the sheet moves — stickers pop in, buttons press,
cards deal — so the static backdrop reads as flat by comparison.

**Where to start:** `ConfettiSheet` in `StickerKit.swift`. It currently draws once
into a `Canvas` from a seeded LCG, which is deliberate: positions must not
reshuffle between redraws. Add a `TimelineView(.animation)` and offset each dot
by a slow sine of its index so the scatter stays stable while it breathes. Keep
the amplitude small — this is ambience, not weather. Must respect
`accessibilityReduceMotion`, and stay off on `GameView` where it would distract
from the cards.

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
