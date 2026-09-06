"""Six around the pediment.

One construction — tympanum, architrave, columns, stylobate — with the
variables that actually change how a mark behaves at size: how many columns,
how heavy the strokes, whether the ground is paper or ink, whether the name is
there at all, and whether anything sits in the tympanum.
"""
from PIL import Image, ImageDraw, ImageFont

SERIF = "/usr/share/fonts/truetype/liberation/LiberationSerif-Regular.ttf"
S = 1024
CREAM = (243, 239, 230)
INK = (17, 17, 19)

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

def shaft(d, cx, top, bottom, width, fill, flutes=0, flute_fill=None, flute_w=4):
    half = width / 2
    d.rectangle([cx - half, top + width * 0.30, cx + half, bottom - width * 0.26], fill=fill)
    d.rectangle([cx - half * 1.40, top, cx + half * 1.40, top + width * 0.30], fill=fill)
    d.rectangle([cx - half * 1.44, bottom - width * 0.26, cx + half * 1.44, bottom], fill=fill)
    if flutes:
        step = width / (flutes + 1)
        for i in range(1, flutes + 1):
            x = cx - half + step * i
            d.line([x, top + width * 0.44, x, bottom - width * 0.40],
                   fill=flute_fill, width=flute_w)

def pediment(ground, mark, *, columns=4, weight=10, solid_tympanum=False,
             steps=1, name=None, frame=False, motif=None, top=0.115,
             base=0.755, flutes=2, span=0.895):
    im = Image.new("RGB", (S, S), ground)
    d = ImageDraw.Draw(im)
    left, right = S * (1 - span), S * span
    apex = S * top
    eaves = S * (top + 0.20)

    if solid_tympanum:
        d.polygon([(S/2, apex), (right, eaves), (left, eaves)], fill=mark)
    else:
        d.line([(S/2, apex), (right, eaves)], fill=mark, width=weight)
        d.line([(S/2, apex), (left, eaves)], fill=mark, width=weight)
        d.line([(left, eaves), (right, eaves)], fill=mark, width=weight)

    if motif == "V":
        # Sized to the gable it sits in, not to the tile.
        f = ImageFont.truetype(SERIF, 186)
        w = d.textlength("V", font=f)
        d.text((S/2 - w/2, eaves - S*0.022), "V", font=f,
               fill=ground if solid_tympanum else mark, anchor="ls")

    architrave_top = eaves + S * 0.025
    d.rectangle([left - S*0.02, architrave_top, right + S*0.02,
                 architrave_top + S * 0.06], fill=mark)

    shaft_top = architrave_top + S * 0.085
    shaft_bottom = S * base
    width = S * (0.095 if columns == 4 else 0.125)
    positions = {3: (0.235, 0.5, 0.765), 4: (0.19, 0.395, 0.605, 0.81)}[columns]
    for cx in positions:
        shaft(d, S * cx, shaft_top, shaft_bottom, width, mark,
              flutes=flutes, flute_fill=ground, flute_w=5 if columns == 3 else 4)

    y = shaft_bottom + S * 0.02
    for i in range(steps):
        inset = 0.06 - i * 0.022
        d.rectangle([S * inset, y, S * (1 - inset), y + S * 0.045], fill=mark)
        y += S * 0.055

    if frame:
        d.rectangle([S*0.05, S*0.05, S*0.95, S*0.95], outline=mark, width=5)
        d.rectangle([S*0.072, S*0.072, S*0.928, S*0.928], outline=mark, width=2)
    if name:
        tracked(d, name, ImageFont.truetype(SERIF, 84), S/2, S*0.925, 24, mark)
    return im

# 1 — Plate. Ink on paper, the name beneath, one step. (The one you picked.)
save(pediment(CREAM, INK, name="VAMP"), "ped-plate")

# 2 — Relief. The same front reversed out of ink, and no name at all.
save(pediment(INK, CREAM, base=0.80, steps=2), "ped-relief")

# 3 — Three. Fewer, heavier columns — the version that holds at 20pt.
save(pediment(CREAM, INK, columns=3, weight=14, base=0.775, steps=2, flutes=1), "ped-three")

# 4 — Sealed. The front inside the drawn border, name in the frame.
save(pediment(CREAM, INK, frame=True, top=0.155, base=0.71, name="VAMP",
              span=0.855, flutes=2), "ped-sealed")

# 5 — Tympanum. The letter carried in the gable, the way a temple carries one.
save(pediment(INK, CREAM, solid_tympanum=True, motif="V", top=0.10, base=0.79, steps=2), "ped-tympanum")

# 6 — Steps. Paper, no name, three stylobate courses: all architecture.
save(pediment(CREAM, INK, base=0.70, steps=3, columns=4, flutes=2), "ped-steps")

print("wrote 6")
