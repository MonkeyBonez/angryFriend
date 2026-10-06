# App Store screenshots

`gen.py` renders the five App Store screenshots with headless Chrome — the same
design as the "01 · Sticker Bomb" frames in the Figma file
(https://www.figma.com/design/pIpiEUQGuckn5fsCJ2cCgB/), with the phone bled off
the bottom on purpose and a drawn 9:41 status bar covering the real one.

1. Drop the device screenshots into `shots/` as `shot-home.png`,
   `shot-game-start.png`, `shot-game-mid.png`, `shot-gotcha.png`,
   `shot-snip.png` (1179×2556, iPhone 14 Pro) plus `icon-face.png`
   (the transparent icon face from `angryFriend/AppIcon.icon`).
2. `python3 gen.py` → `final/6.5in-1284x2778/` and `final/6.9in-1320x2868/`.

Needs Google Chrome and the SF Pro Rounded / SF Pro Display fonts installed.
`shots/` and `final/` are gitignored (personal photos).
