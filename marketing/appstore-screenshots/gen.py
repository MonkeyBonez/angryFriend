#!/usr/bin/env python3
"""Render the final Angry Friend App Store screenshots (mirrors the Figma
"01 · Sticker Bomb" frames S1–S4 + S6-on-mint) with headless Chrome."""
import math, os, subprocess, sys, html

HERE = os.path.dirname(os.path.abspath(__file__))
SHOTS = os.path.join(HERE, "shots")   # put shot-*.png + icon-face.png here (gitignored)
OUT = os.path.join(HERE, "final")
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
W, H = 1284, 2778
INK, SUN, PINK, WHITE = "#211A0D", "#FFD948", "#FF4D8D", "#FFFFFF"
TILES = ["#BFE3FF", "#FFC9DD", "#CFF5D8", "#FFE0B8", "#E4D6FF"]

SCREENS = [
    dict(file="01-home", bg=SUN, dots="sun", icon=True, kicker="THE PARTY GAME",
         headline="Turn your camera roll\ninto a party game", hl="party game", hlc=PINK,
         shot="shot-home.png", band=SUN, seed=11 + 0 * 7),
    dict(file="02-game-start", bg=PINK, dots="dark", glyph="👀", kicker="ONE CARD IS FURIOUS",
         headline="Don't pick\nthe angry one", hl="angry", hlc=SUN,
         shot="shot-game-start.png", band=SUN, seed=11 + 1 * 7),
    dict(file="03-mid-game", bg="#3D6BFF", dots="dark", glyph="😬", kicker="YOUR FRIENDS. YOUR DECK.",
         headline="A personal twist\non the classic game", hl="personal twist", hlc=SUN,
         shot="shot-game-mid.png", band="#FFC044", seed=11 + 2 * 7),
    dict(file="04-gotcha", bg="#FF3B30", dots="dark", glyph="💥", kicker="GOTCHA!",
         headline="See who has to\ntake a penalty", hl="penalty", hlc=SUN,
         shot="shot-gotcha.png", band="linear-gradient(#F7CA4C, #F7C44F)", seed=11 + 3 * 7),
    dict(file="05-privacy", bg="#2FBF71", dots="dark", glyph="🔒", kicker="100% ON-DEVICE",
         headline="Your photos never\nleave your phone", hl="never leave", hlc=SUN,
         shot="shot-snip.png", band="#F6D146", seed=11 + 5 * 7),
]


def dots(seed, palette):
    s = seed
    def rnd():
        nonlocal s
        s = (s * 9301 + 49297) % 233280
        return s / 233280
    out = []
    for i in range(34):
        d = 8 + round(rnd() * 22)
        x = round(rnd() * (W - d)); y = round(rnd() * (H - d))
        c, a = palette[i % len(palette)]
        out.append(f'<i style="left:{x}px;top:{y}px;width:{d}px;height:{d}px;background:{c};opacity:{a}"></i>')
    return "".join(out)


def sector(cx, cy, R, inner, a0=-135, a1=-45):
    r = R * inner
    p = lambda rad, a: (cx + rad * math.cos(math.radians(a)), cy + rad * math.sin(math.radians(a)))
    x0, y0 = p(R, a0); x1, y1 = p(R, a1); x2, y2 = p(r, a1); x3, y3 = p(r, a0)
    return f'<path d="M{x0:.1f} {y0:.1f} A{R:.1f} {R:.1f} 0 0 1 {x1:.1f} {y1:.1f} L{x2:.1f} {y2:.1f} A{r:.1f} {r:.1f} 0 0 0 {x3:.1f} {y3:.1f} Z" fill="{INK}"/>'


def status_bar(w, band):
    k = w / 895
    bars = ""; x = 640 * k
    for hgt in (9, 14, 18, 23):
        bars += f'<rect x="{x:.1f}" y="{80*k - hgt*k:.1f}" width="{7*k:.1f}" height="{hgt*k:.1f}" rx="{2*k:.1f}" fill="{INK}"/>'
        x += 10.4 * k
    wifi = "".join(sector(717 * k, 82 * k, d / 2 * k, inner) for d, inner in ((55, .8), (36, .7), (18, .4)))
    bat = (f'<rect x="{770*k+1.25*k:.1f}" y="{55*k+1.25*k:.1f}" width="{57*k-2.5*k:.1f}" height="{27*k-2.5*k:.1f}" rx="{8*k-1.25*k:.1f}" fill="none" stroke="{INK}" stroke-opacity=".4" stroke-width="{2.5*k:.1f}"/>'
           f'<rect x="{775*k:.1f}" y="{60*k:.1f}" width="{47*k:.1f}" height="{17*k:.1f}" rx="{4*k:.1f}" fill="{INK}"/>'
           f'<rect x="{829*k:.1f}" y="{64*k:.1f}" width="{3*k:.1f}" height="{9*k:.1f}" rx="{1.5*k:.1f}" fill="{INK}" fill-opacity=".4"/>')
    hgt = round(114 * k)
    return (f'<div class="band" style="height:{hgt}px;background:{band}">'
            f'<div class="time" style="font-size:{39*k:.1f}px;left:{162*k:.1f}px;top:{68*k:.1f}px">9:41</div>'
            f'<svg width="{w}" height="{hgt}" viewBox="0 0 {w} {hgt}">{bars}{wifi}{bat}</svg></div>')


def highlight(text, hl, color):
    text = html.escape(text).replace("\n", "<br>")
    # the highlight may span the <br>
    plain = html.escape(hl)
    if plain in text:
        return text.replace(plain, f'<span style="color:{color}">{plain}</span>', 1)
    a, b = hl.split(" ", 1)
    key = f"{html.escape(a)}<br>{html.escape(b)}"
    return text.replace(key, f'<span style="color:{color}">{key}</span>', 1)


def page(sc, frame_h, zoom):
    y = 120
    top = ""
    if sc.get("icon"):
        top += f'<div class="icon" style="left:542px;top:{y}px"><img src="shots/icon-face.png"></div>'
        y += 230
    else:
        top += f'<div class="glyph" style="top:{y}px">{sc["glyph"]}</div>'
        y += 180 + 30
    top += f'<div class="tape" style="top:{y}px">{html.escape(sc["kicker"])}</div>'
    y += 68 + 40
    size = 92 if len(sc["headline"].replace("\n", " ")) > 30 else 100
    shadow = html.escape(sc["headline"]).replace("\n", "<br>")
    fill = highlight(sc["headline"], sc["hl"], sc["hlc"])
    top += (f'<div class="head" style="top:{y}px;font-size:{size}px">'
            f'<div class="layer shadow">{shadow}</div><div class="layer fill">{fill}</div></div>')
    palette = [(c, .9) for c in TILES] + [(INK, .18)] if sc["dots"] == "sun" else [(WHITE, .55), (SUN, .75), (INK, .2)]
    phone_w = 1060; phone_h = round(phone_w * 2556 / 1179)
    phone = (f'<div class="phone" style="left:102px;top:838px;width:{phone_w}px;height:{phone_h}px;border-radius:158px">'
             f'<img src="shots/{sc["shot"]}">{status_bar(phone_w, sc["band"])}</div>')
    return f"""<!doctype html><html><head><meta charset="utf-8"><style>
html,body{{margin:0;padding:0;background:{sc['bg']}}}
body{{zoom:{zoom}}}
.frame{{position:relative;width:{W}px;height:{frame_h}px;overflow:hidden;background:{sc['bg']};font-family:"SF Pro Rounded","SF Pro Display",system-ui}}
.dots i{{position:absolute;border-radius:50%}}
.icon{{position:absolute;width:200px;height:200px;box-sizing:border-box;border:6px solid {INK};border-radius:45px;background:#fff;box-shadow:8px 8px 0 {INK};display:flex;align-items:center;justify-content:center}}
.icon img{{width:126px;height:126px;object-fit:contain}}
.glyph{{position:absolute;left:0;width:{W}px;text-align:center;font-size:150px;line-height:1;font-family:"Apple Color Emoji"}}
.tape{{position:absolute;left:50%;transform:translateX(-50%) rotate(-2.5deg);padding:11px 27px;background:#fff;border:3px solid {INK};box-shadow:6px 6px 0 {INK};font-weight:800;font-size:40px;line-height:1;letter-spacing:.06em;color:{INK};white-space:nowrap}}
.head{{position:absolute;left:140px;width:1004px;text-align:center;font-weight:800;line-height:1.08;letter-spacing:-.01em}}
.head .layer{{position:absolute;left:0;right:0;top:0;-webkit-text-stroke:16px {INK};paint-order:stroke fill}}
.head .shadow{{color:{INK};transform:translate(10px,10px)}}
.head .fill{{color:#fff}}
.phone{{position:absolute;box-sizing:content-box;border:10px solid {INK};box-shadow:18px 18px 0 {INK};overflow:hidden;background:{INK}}}
.phone>img{{position:absolute;left:0;top:0;width:100%;height:100%;object-fit:cover;display:block}}
.band{{position:absolute;left:0;top:0;width:100%}}
.band .time{{position:absolute;transform:translate(-50%,-50%);font-family:"SF Pro Display","SF Pro Rounded";font-weight:600;color:{INK};line-height:1}}
.band svg{{position:absolute;left:0;top:0}}
</style></head><body><div class="frame"><div class="dots">{dots(sc['seed'], palette)}</div>{top}{phone}</div></body></html>"""


def main():
    os.makedirs(OUT, exist_ok=True)
    variants = [("6.5in-1284x2778", W, H, 1.0, H), ("6.9in-1320x2868", 1320, 2868, 1320 / W, round(2868 / (1320 / W)))]
    for sc in SCREENS:
        for name, ww, hh, zoom, frame_h in variants:
            d = os.path.join(OUT, name); os.makedirs(d, exist_ok=True)
            htmlpath = os.path.join(HERE, f"_{sc['file']}-{name}.html")
            with open(htmlpath, "w") as f:
                f.write(page(sc, frame_h, zoom))
            png = os.path.join(d, f"{sc['file']}.png")
            subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
                            f"--window-size={ww},{hh}", f"--screenshot={png}", f"file://{htmlpath}"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
            print("wrote", png)


if __name__ == "__main__":
    main()
