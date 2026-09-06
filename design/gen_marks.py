"""Drawn marks, not framings of the plate.

The first twelve were all one photograph with the wordmark moved around it,
so they could only ever differ by a shade. These are constructed instead:
geometry and type, no engraving at all, which is also what lets them survive
being 40pt on a Home Screen.
"""
from PIL import Image, ImageDraw, ImageFont

SERIF = "/usr/share/fonts/truetype/liberation/LiberationSerif-Regular.ttf"
S = 1024
CREAM = (243, 239, 230)
INK = (17, 17, 19)
STONE = (196, 191, 181)

def tracked(d, text, font, cx, baseline, spacing, fill):
    widths = [d.textlength(c, font=font) for c in text]
    x = cx - (sum(widths) + spacing * (len(text) - 1)) / 2
    for c, w in zip(text, widths):
        d.text((x, baseline), c, font=font, fill=fill, anchor="ls")
        x += w + spacing

def save(im, name, preview=280):
    im.save(f"icons/{name}.png")
    mask = Image.new("L", im.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, S, S], radius=int(S * 0.2237), fill=255)
    out = Image.new("RGBA", im.size, (0, 0, 0, 0))
    out.paste(im, (0, 0), mask)
    out.resize((preview, preview), Image.LANCZOS).save(f"{name}.png")
    out.convert("RGB").resize((220, 220), Image.LANCZOS).save(f"{name}.jpg", quality=74, optimize=True)

def column(d, cx, top, bottom, width, fill, flutes=3, flute_fill=None):
    """A shaft with a capital and a base — the only ornament these marks use."""
    half = width / 2
    d.rectangle([cx - half, top + width * 0.34, cx + half, bottom - width * 0.30], fill=fill)
    d.rectangle([cx - half * 1.42, top, cx + half * 1.42, top + width * 0.34], fill=fill)
    d.rectangle([cx - half * 1.46, bottom - width * 0.30, cx + half * 1.46, bottom], fill=fill)
    if flute_fill:
        step = width / (flutes + 1)
        for i in range(1, flutes + 1):
            x = cx - half + step * i
            d.line([x, top + width * 0.46, x, bottom - width * 0.42], fill=flute_fill, width=4)

# A — Portal. A temple cut out of a solid tile: all silhouette, no picture.
im = Image.new("RGB", (S, S), INK)
d = ImageDraw.Draw(im)
d.polygon([(S*0.5, S*0.13), (S*0.90, S*0.36), (S*0.10, S*0.36)], fill=CREAM)
d.rectangle([S*0.10, S*0.385, S*0.90, S*0.45], fill=CREAM)
for cx in (0.205, 0.40, 0.60, 0.795):
    column(d, S*cx, S*0.475, S*0.82, S*0.10, CREAM)
d.rectangle([S*0.07, S*0.845, S*0.93, S*0.895], fill=CREAM)
save(im, "mark-portal")

# B — Fluted V. The letter built as two shafts, fluted like the order.
im = Image.new("RGB", (S, S), INK)
d = ImageDraw.Draw(im)
d.polygon([(S*0.20, S*0.20), (S*0.335, S*0.20), (S*0.52, S*0.70), (S*0.44, S*0.79)], fill=CREAM)
d.polygon([(S*0.80, S*0.20), (S*0.665, S*0.20), (S*0.48, S*0.70), (S*0.56, S*0.79)], fill=CREAM)
d.polygon([(S*0.437, S*0.735), (S*0.563, S*0.735), (S*0.50, S*0.845)], fill=CREAM)
d.rectangle([S*0.155, S*0.155, S*0.375, S*0.205], fill=CREAM)
d.rectangle([S*0.625, S*0.155, S*0.845, S*0.205], fill=CREAM)
for k in (-1, 0, 1):
    d.line([S*(0.255 + k*0.028), S*0.245, S*(0.455 + k*0.024), S*0.70], fill=INK, width=5)
    d.line([S*(0.745 - k*0.028), S*0.245, S*(0.545 - k*0.024), S*0.70], fill=INK, width=5)
save(im, "mark-flutedv")

# C — Seal. A ring of ticks around one letter: a stamp, not a scene.
im = Image.new("RGB", (S, S), INK)
d = ImageDraw.Draw(im)
d.ellipse([S*0.085, S*0.085, S*0.915, S*0.915], outline=STONE, width=5)
d.ellipse([S*0.145, S*0.145, S*0.855, S*0.855], outline=STONE, width=2)
import math
for i in range(48):
    a = math.radians(i * 7.5)
    r0, r1 = S*0.395, S*0.425
    d.line([S/2 + r0*math.cos(a), S/2 + r0*math.sin(a),
            S/2 + r1*math.cos(a), S/2 + r1*math.sin(a)], fill=STONE, width=3)
f = ImageFont.truetype(SERIF, 430)
w = d.textlength("V", font=f)
d.text((S/2 - w/2, S*0.66), "V", font=f, fill=CREAM, anchor="ls")
tracked(d, "VAMP", ImageFont.truetype(SERIF, 74), S/2, S*0.775, 20, STONE)
save(im, "mark-seal")

# D — Letterpress. Type alone, set between rules, on paper.
im = Image.new("RGB", (S, S), CREAM)
d = ImageDraw.Draw(im)
d.line([S*0.14, S*0.315, S*0.86, S*0.315], fill=INK, width=6)
d.line([S*0.14, S*0.345, S*0.86, S*0.345], fill=INK, width=2)
tracked(d, "VAMP", ImageFont.truetype(SERIF, 230), S/2, S*0.60, 26, INK)
d.line([S*0.14, S*0.655, S*0.86, S*0.655], fill=INK, width=2)
d.line([S*0.14, S*0.685, S*0.86, S*0.685], fill=INK, width=6)
tracked(d, "ASSISTANT", ImageFont.truetype(SERIF, 62), S/2, S*0.79, 22, (74, 72, 68))
save(im, "mark-letterpress")

# E — Pediment. The building reduced to its front, ink on paper.
im = Image.new("RGB", (S, S), CREAM)
d = ImageDraw.Draw(im)
d.line([(S*0.5, S*0.115), (S*0.895, S*0.315)], fill=INK, width=10)
d.line([(S*0.5, S*0.115), (S*0.105, S*0.315)], fill=INK, width=10)
d.line([(S*0.105, S*0.315), (S*0.895, S*0.315)], fill=INK, width=10)
d.rectangle([S*0.085, S*0.34, S*0.915, S*0.40], fill=INK)
for cx in (0.19, 0.395, 0.605, 0.81):
    column(d, S*cx, S*0.425, S*0.735, S*0.095, INK, flutes=2, flute_fill=CREAM)
d.rectangle([S*0.06, S*0.755, S*0.94, S*0.80], fill=INK)
tracked(d, "VAMP", ImageFont.truetype(SERIF, 88), S/2, S*0.905, 24, INK)
save(im, "mark-pediment")

print("wrote 5 marks")
