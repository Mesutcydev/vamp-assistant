from kit import head, TAIL
from tokens import DARK as t

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

cells = "".join(f'''<div style="display:flex;flex-direction:column;gap:9px">
  <img src="{n}.jpg" alt="" style="width:100%;border-radius:22.37%;display:block">
  <div>
    <div style="font-size:13px;font-weight:600">{title}</div>
    <div class="c2" style="margin-top:3px;line-height:15px">{note}</div>
  </div>
</div>''' for n, title, note in NAMES)

html = head(t, 900, 1080) + f'''<div class="screen" style="width:900px;height:1080px">
  <div class="atmos"></div>
  <div class="layer" style="padding:26px 30px;gap:20px;overflow:hidden">
    <div>
      <div class="t1" style="font-size:26px">Icon studies</div>
      <div class="sub" style="margin-top:6px">Twelve cuts of one engraving in one serif. The first row follows the drawn border, which is the device that still reads at 40pt.</div>
    </div>
    <div style="display:grid;grid-template-columns:repeat(4, minmax(0, 1fr));gap:20px 20px">
      {cells}
    </div>
    <div class="fn" style="line-height:18px">Built at 1024 from WindowAtmosphere — the clean plate. VampBackdrop carries the wordmark baked in, which is why type drawn over it printed VAMP twice.</div>
  </div>
</div>
''' + TAIL
open("IconStudies.dc.html","w").write(html)
print("ok")
