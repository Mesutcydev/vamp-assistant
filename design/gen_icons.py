from PIL import Image, ImageDraw, ImageFont, ImageOps, ImageFilter, ImageEnhance

# The clean plate. VampBackdrop already carries the wordmark baked in, so
# drawing type over it printed VAMP twice.
SRC = "../App/Assets.xcassets/WindowAtmosphere.imageset/WindowAtmosphere.jpg"
ATMOS = "../App/Assets.xcassets/WindowAtmosphere.imageset/WindowAtmosphere.jpg"
SERIF = "/usr/share/fonts/truetype/liberation/LiberationSerif-Regular.ttf"
S = 1024
CREAM = (244, 240, 231)
INK = (20, 20, 22)

def plate(path=SRC, box=None, size=S, contrast=1.0, bright=1.0):
    im = Image.open(path).convert("L")
    if box:
        im = im.crop(box)
    im = ImageOps.fit(im, (size, size), Image.LANCZOS)
    if contrast != 1.0: im = ImageEnhance.Contrast(im).enhance(contrast)
    if bright != 1.0: im = ImageEnhance.Brightness(im).enhance(bright)
    return im.convert("RGB")

def tracked(draw, text, font, cx, baseline, spacing, fill):
    """Letterspaced, drawn from the baseline — the top-left origin is what put
    the wordmark through the bottom edge of the tile."""
    widths = [draw.textlength(ch, font=font) for ch in text]
    total = sum(widths) + spacing * (len(text) - 1)
    x = cx - total / 2
    for ch, w in zip(text, widths):
        draw.text((x, baseline), ch, font=font, fill=fill, anchor="ls")
        x += w + spacing

def vignette(im, strength=0.75, inner=0.35):
    """A darkened edge so type has somewhere quiet to sit."""
    mask = Image.new("L", im.size, 0)
    d = ImageDraw.Draw(mask)
    r = int(im.size[0] * inner)
    d.ellipse([-r, -r, im.size[0] + r, im.size[1] + r], fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(im.size[0] * 0.22))
    dark = Image.new("RGB", im.size, (0, 0, 0))
    return Image.composite(im, Image.blend(im, dark, strength), mask)

def band(im, height=0.34, strength=0.62):
    """A gradient foot, so a wordmark reads without a solid bar."""
    grad = Image.new("L", (1, im.size[1]), 0)
    px = grad.load()
    start = int(im.size[1] * (1 - height))
    for y in range(im.size[1]):
        t = 0 if y < start else (y - start) / max(1, im.size[1] - start)
        px[0, y] = int(255 * (t ** 1.5) * strength)
    grad = grad.resize(im.size)
    return Image.composite(Image.new("RGB", im.size, (0, 0, 0)), im, grad)

def rounded(im, radius=0.2237):
    mask = Image.new("L", im.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, im.size[0], im.size[1]],
                                           radius=int(im.size[0] * radius), fill=255)
    out = Image.new("RGBA", im.size, (0, 0, 0, 0))
    out.paste(im, (0, 0), mask)
    return out

def save(im, name, preview=280):
    im.convert("RGB").save(f"icons/{name}.png")
    rounded(im).resize((preview, preview), Image.LANCZOS).save(f"{name}.png")

# 1 — Portico. The plate as it is, with the wordmark on a gradient foot.
im = band(plate(box=(256, 0, 1280, 1024)), height=0.40, strength=0.66)
d = ImageDraw.Draw(im)
tracked(d, "VAMP", ImageFont.truetype(SERIF, 186), S/2, S*0.845, 26, CREAM)
save(im, "icon-portico")

# 2 — Columns. Crop to the order itself; the wordmark sits in the shafts.
im = band(plate(box=(560, 60, 1400, 900), contrast=1.08), height=0.36, strength=0.7)
d = ImageDraw.Draw(im)
tracked(d, "VAMP", ImageFont.truetype(SERIF, 160), S/2, S*0.855, 32, CREAM)
save(im, "icon-columns")

# 3 — Monogram. One letter, cut out of the plate by a vignette.
im = vignette(plate(box=(330, 30, 1250, 950)), strength=0.72, inner=0.18)
d = ImageDraw.Draw(im)
f = ImageFont.truetype(SERIF, 660)
w = d.textlength("V", font=f)
d.text((S/2 - w/2, S*0.70), "V", font=f, fill=CREAM, anchor="ls")
save(im, "icon-monogram")

# 4 — Statue. The figure, off-centre, with the name small at the foot.
im = band(plate(box=(1108, 288, 1428, 608), contrast=1.12, bright=0.94), height=0.44, strength=0.86)
d = ImageDraw.Draw(im)
tracked(d, "VAMP", ImageFont.truetype(SERIF, 112), S/2, S*0.885, 20, CREAM)
save(im, "icon-statue")

# 5 — Medallion. The plate held inside a ring, no type at all.
base = Image.new("RGB", (S, S), INK)
disc = plate(box=(430, 60, 1150, 780), size=int(S*0.76), contrast=1.05)
mask = Image.new("L", disc.size, 0)
ImageDraw.Draw(mask).ellipse([0, 0, disc.size[0], disc.size[1]], fill=255)
base.paste(disc, (int(S*0.12), int(S*0.12)), mask)
d = ImageDraw.Draw(base)
d.ellipse([S*0.12, S*0.12, S*0.88, S*0.88], outline=(150, 148, 143), width=3)
d.ellipse([S*0.09, S*0.09, S*0.91, S*0.91], outline=(90, 89, 86), width=2)
save(base, "icon-medallion")

# 6 — Plate. Cream ground, ink engraving: the app in light mode.
eng = plate(box=(400, 100, 1200, 900), contrast=1.2, bright=1.22)
paper = Image.new("RGB", (S, S), CREAM)
im = Image.blend(paper, eng.convert("RGB"), 0.55)
d = ImageDraw.Draw(im)
tracked(d, "VAMP", ImageFont.truetype(SERIF, 176), S/2, S*0.83, 26, (26, 25, 23))
save(im, "icon-plate")

# 7 — Rule. Wordmark over a hairline, with the second word tracked beneath it.
im = vignette(plate(box=(350, 80, 1250, 980), bright=0.72, contrast=1.05), strength=0.72, inner=0.26)
d = ImageDraw.Draw(im)
tracked(d, "VAMP", ImageFont.truetype(SERIF, 196), S/2, S*0.53, 28, CREAM)
d.line([S*0.27, S*0.585, S*0.73, S*0.585], fill=(206, 201, 190), width=3)
tracked(d, "ASSISTANT", ImageFont.truetype(SERIF, 62), S/2, S*0.665, 20, (226, 221, 210))
save(im, "icon-rule")

# 8 — Frame. Full-bleed plate inside a drawn border, monogram in the corner.
im = plate(box=(280, 10, 1290, 1020), contrast=1.06, bright=0.92)
d = ImageDraw.Draw(im)
d.rectangle([S*0.055, S*0.055, S*0.945, S*0.945], outline=(226, 222, 212), width=4)
d.rectangle([S*0.055, S*0.735, S*0.945, S*0.945], fill=(18, 18, 20))
tracked(d, "VAMP", ImageFont.truetype(SERIF, 128), S/2, S*0.885, 24, CREAM)
save(im, "icon-frame")

print("wrote 8")
