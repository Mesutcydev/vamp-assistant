"""Cut the shipping app icon from the tympanum mark.

One master drawing, two shapes: iOS gets a full-bleed opaque square (the
system masks it), macOS gets the inset rounded rect the Dock expects. Below
32px the flutes and the letter close up, so the small sizes are drawn from a
simplified master rather than downsampled from the large one.
"""
import json, sys
from PIL import Image, ImageDraw
sys.argv = [sys.argv[0]]
import importlib.util
spec = importlib.util.spec_from_file_location("ped", "gen_pediment.py")
ped = importlib.util.module_from_spec(spec)
# gen_pediment writes files on import; run it in a scratch dir-safe way
import os
os.makedirs("icons", exist_ok=True)
spec.loader.exec_module(ped)

S = 1024
OUT = "../App/Assets.xcassets/AppIcon.appiconset"

def master(simple=False):
    """The tympanum: solid gable with the letter reversed out, on ink."""
    return ped.pediment(ped.INK, ped.CREAM, solid_tympanum=True, motif="V",
                        top=0.10, base=0.79, steps=2,
                        columns=3 if simple else 4,
                        flutes=0 if simple else 2,
                        weight=14 if simple else 10)

big = master().convert("RGB")
small = master(simple=True).convert("RGB")

def mac_tile(size):
    """macOS: the art inset in a rounded rect with a transparent margin."""
    art = (small if size <= 32 else big).resize((size, size), Image.LANCZOS)
    inset = round(size * 0.098)
    side = size - inset * 2
    tile = art.resize((side, side), Image.LANCZOS)
    mask = Image.new("L", (side, side), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, side, side],
                                           radius=round(side * 0.2237), fill=255)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(tile, (inset, inset), mask)
    return out

for size in (16, 32, 64, 128, 256, 512, 1024):
    mac_tile(size).save(f"{OUT}/icon_{size}.png")

# iOS: full bleed, no alpha — the platform draws the mask itself.
big.save(f"{OUT}/icon_ios_1024.png")

contents = json.load(open(f"{OUT}/Contents.json"))
for entry in contents["images"]:
    if entry.get("platform") == "ios":
        entry["filename"] = "icon_ios_1024.png"
json.dump(contents, open(f"{OUT}/Contents.json", "w"), indent=2)
print("wrote app icon")
