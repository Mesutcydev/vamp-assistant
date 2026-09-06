from kit import head, TAIL
from tokens import DARK as t

MARKS = [
 ("mark-portal",      "Portal",        "A temple cut out of a solid tile. All silhouette, no picture — the one that still reads at 20pt."),
 ("mark-flutedv",     "Fluted V",      "The letter built as two shafts of the order, fluted, with a capital across the top."),
 ("mark-seal",        "Seal",          "A stamp rather than a scene: a ring of ticks around one letter, name beneath."),
 ("mark-letterpress", "Letterpress",   "Type alone, set between rules on paper. No mark at all — the name is the mark."),
 ("mark-pediment",    "Pediment",      "The building reduced to its front, drawn in ink on paper."),
]

NAMES = [
 ("icon-frame",       "Frame",         "Drawn border, name in a solid foot. Reads as a plate in a book."),
 ("icon-frame-light", "Frame, light",  "The same construction on paper — the border is what survives being shrunk to 40pt."),
 ("icon-cartouche",   "Cartouche",     "The plate cut to an arch, the way the building ends, name in the ink margin below."),
 ("icon-placard",     "Placard",       "The name on a museum label rather than across the picture. Double rule, small plaque."),
 ("icon-masthead",    "Masthead",      "An editorial band across the top: the word reads before the engraving does."),
 ("icon-portico",     "Portico",       "The plate as it is, wordmark on a gradient foot. Closest to what ships."),
 ("icon-columns",     "Columns",       "Cropped to the order itself — reads where the wide scene turns to mush."),
 ("icon-monogram",    "Monogram",      "One letter cut out of the plate. The only one that works with no name at all."),
 ("icon-statue",      "Statue",        "The figure instead of the architecture: a face on the Home Screen."),
 ("icon-medallion",   "Medallion",     "The plate in a ring on flat ink, no type, so it never repeats the label beneath it."),
 ("icon-plate",       "Plate",         "Cream ground, ink engraving — the same icon in light."),
 ("icon-rule",        "Rule",          "Wordmark over a hairline with the second word tracked beneath. The most formal."),
]

def grid(items):
    return "".join(f'''<div style="display:flex;flex-direction:column;gap:9px">
  <img src="{n}.jpg" alt="" style="width:100%;border-radius:22.37%;display:block">
  <div>
    <div style="font-size:13px;font-weight:600">{title}</div>
    <div class="c2" style="margin-top:3px;line-height:15px">{note}</div>
  </div>
</div>''' for n, title, note in items)

html = head(t, 1180, 1000) + f'''<div class="screen" style="width:1180px;height:1000px">
  <div class="atmos"></div>
  <div class="layer" style="padding:26px 30px;gap:20px;overflow:hidden">
    <div>
      <div class="t1" style="font-size:26px">Icon studies</div>
      <div class="sub" style="margin-top:6px">Two families. The marks are constructed — geometry and type, nothing photographic — which is what lets them survive being 40pt on a Home Screen. The framings below are all one plate, so they can only differ by a shade.</div>
    </div>
    <div class="cap">Drawn marks — geometry and type, no engraving</div>
    <div style="display:grid;grid-template-columns:repeat(5, minmax(0, 1fr));gap:18px">
      {grid(MARKS)}
    </div>
    <div class="cap" style="padding-top:6px">Framings of the plate</div>
    <div style="display:grid;grid-template-columns:repeat(6, minmax(0, 1fr));gap:16px">
      {grid(NAMES)}
    </div>
    <div class="fn" style="line-height:18px">Built at 1024 from WindowAtmosphere — the clean plate. VampBackdrop carries the wordmark baked in, which is why type drawn over it printed VAMP twice.</div>
  </div>
</div>
''' + TAIL
open("IconStudies.dc.html","w").write(html)
print("ok")
