#!/usr/bin/env python3
"""Draw a placeholder sponsor panel that matches counter's scorebug.

The scorebug (counter/public/bug.html) is a 640x360 tile: navy gradient
#1b3a6d -> #0a1a38, a 4px #3987e5 rule along the top, then a 54px title
bar ("<club> - Sheet N", 22px bold #c7d3ea, letter-spaced) closed by a
1px white line at 18% opacity. In the quad layout the sponsor panel sits
beside that tile at the same size, so this script draws the same frame --
rule, title bar, divider -- at 2x (1280x720 by default, scaled by the
compositor) and fills the body with labelled boxes a club replaces with
its real logo and sponsor artwork. The title bar carries "Proudly
supported by" rather than the club name, which the bug already shows.

    tools/sponsor_placeholder.py --out clubs/<club>/streaming/sponsor.png

Needs Pillow and DejaVu Sans (python3-pil, fonts-dejavu-core on Debian).
"""
import argparse

from PIL import Image, ImageDraw, ImageFont

# Colours straight from bug.html
TOP = (0x1B, 0x3A, 0x6D)
BOTTOM = (0x0A, 0x1A, 0x38)
ACCENT = (0x39, 0x87, 0xE5)
TEXT = (0xC7, 0xD3, 0xEA)
WHITE = (0xFF, 0xFF, 0xFF)

FONT_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
FONT_REG = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"


def blend(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", required=True, help="PNG to write")
    ap.add_argument("--width", type=int, default=1280)
    ap.add_argument("--height", type=int, default=720)
    ap.add_argument("--title", default="Proudly supported by",
                    help="text in the title bar (default: 'Proudly supported by')")
    ap.add_argument("--logo-text", default="CLUB LOGO",
                    help="label in the logo box (default: 'CLUB LOGO')")
    args = ap.parse_args()

    W, H = args.width, args.height
    s = W / 640.0                       # scale from the bug's 1x CSS pixels
    px = lambda v: int(round(v * s))

    im = Image.new("RGB", (W, H))
    d = ImageDraw.Draw(im)
    for y in range(H):                  # body gradient, top to bottom
        d.line([(0, y), (W - 1, y)], fill=blend(TOP, BOTTOM, y / (H - 1)))

    # 4px accent rule (body border-top)
    d.rectangle([0, 0, W - 1, px(4) - 1], fill=ACCENT)

    # #topbar: 54px tall, 22px side padding, 1px divider at 18% white
    bar_top, bar_h = px(4), px(54)
    divider_y = bar_top + bar_h
    ov = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    od = ImageDraw.Draw(ov)
    od.rectangle([0, divider_y, W - 1, divider_y + max(1, px(1)) - 1],
                 fill=WHITE + (round(255 * 0.18),))
    im = Image.alpha_composite(im.convert("RGBA"), ov).convert("RGB")
    d = ImageDraw.Draw(im)

    # #sheetlabel: 22px bold, letter-spacing .08em, #c7d3ea, vertically centred
    f_title = ImageFont.truetype(FONT_BOLD, px(22))
    spacing = px(22 * 0.08)
    x = px(22)
    y_mid = bar_top + bar_h / 2
    for ch in args.title:
        bbox = d.textbbox((0, 0), ch, font=f_title, anchor="ls")
        d.text((x, y_mid), ch, font=f_title, fill=TEXT, anchor="lm")
        x += (bbox[2] - bbox[0]) + spacing

    # Body: logo box on the left, sponsor boxes on the right
    f_box = ImageFont.truetype(FONT_BOLD, px(16))
    f_small = ImageFont.truetype(FONT_REG, px(9))
    pad = px(16)
    body_top = divider_y + pad
    body_bot = H - pad
    gap = px(10)
    line_w = max(1, px(1))

    def box(x0, y0, x1, y1, label, sub=None):
        d.rounded_rectangle([x0, y0, x1, y1], radius=px(4),
                            outline=TEXT, width=line_w)
        cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        if sub:
            d.text((cx, cy - px(5)), label, font=f_box, fill=WHITE, anchor="mm")
            d.text((cx, cy + px(9)), sub, font=f_small, fill=TEXT, anchor="mm")
        else:
            d.text((cx, cy), label, font=f_box, fill=WHITE, anchor="mm")

    logo_w = px(150)
    box(pad, body_top, pad + logo_w, body_bot, args.logo_text, "placeholder")

    gx0 = pad + logo_w + gap
    gx1 = W - pad
    cols, rows = 2, 2
    cw = (gx1 - gx0 - gap * (cols - 1)) / cols
    rh = (body_bot - body_top - gap * rows) / (rows + 1)   # +1: wide box
    n = 1
    for r in range(rows):
        for c in range(cols):
            x0 = gx0 + c * (cw + gap)
            y0 = body_top + r * (rh + gap)
            box(x0, y0, x0 + cw, y0 + rh, f"Sponsor {n}")
            n += 1
    y0 = body_top + rows * (rh + gap)
    box(gx0, y0, gx1, body_bot, "Sponsor (wide)")

    im.save(args.out, "PNG", optimize=True)
    print(f"wrote {args.out} ({W}x{H})")


if __name__ == "__main__":
    main()
