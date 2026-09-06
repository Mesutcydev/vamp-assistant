from kit import head, TAIL, ico
from tokens import DARK as t, LIGHT as l

br=t['bright']; a=t['accent']

def sw(hexv, name, note, dark=True):
    pal = t if dark else l
    return f'''<div style="display:flex;align-items:center;gap:10px">
      <div style="width:34px;height:34px;border-radius:9px;background:{hexv};border:0.75px solid {t['rim']};flex:none"></div>
      <div><div style="font-size:13px;font-weight:600">{name}</div>
      <div class="mono" style="font-size:11px;color:{t['text3']};margin-top:1px">{note}</div></div>
    </div>'''

def typ(nm, size, weight, track, sample):
    return f'''<div style="display:flex;align-items:baseline;gap:14px;padding:7px 0;border-bottom:0.75px solid {t['sep']}">
      <div class="mono" style="font-size:11px;color:{t['text3']};width:150px;flex:none">{nm} · {size}/{weight}{track}</div>
      <div style="font-size:{size}px;font-weight:{weight};letter-spacing:{track or '0'}">{sample}</div>
    </div>'''

foundations = head(t, 880, 1180) + f'''<div class="screen" style="width:880px;height:1180px">
  <div class="atmos"></div>
  <div class="layer" style="padding:26px 30px;gap:24px;overflow:hidden">

    <div>
      <div class="t1" style="font-size:28px">Vamp Assistant — iOS foundations</div>
      <div class="sub" style="margin-top:6px">Every value below is the one the app ships: RemoteSurface, AccentPalette.graphite, RemoteBackdrop.</div>
    </div>

    <div style="display:grid;grid-template-columns:repeat(2, minmax(0, 1fr));gap:22px">
      <div class="glass" style="padding:16px">
        <div class="cap" style="padding-bottom:12px">Dark — the default</div>
        <div style="display:grid;grid-template-columns:repeat(2, minmax(0, 1fr));gap:12px">
          {sw(t['ground'],'ground','#0F0F10 · behind everything')}
          {sw(t['card'],'card','#1A1A1C · rows, sheets')}
          {sw(t['well'],'well','#252528 · fields, chips')}
          {sw('#686868','accent','graphite accentDark')}
          {sw('#9A9A9E','bright','bright · glyphs, dots')}
          {sw('#FFFFFF','separator','9% hairline · 13% rim')}
        </div>
      </div>
      <div class="glass" style="padding:16px">
        <div class="cap" style="padding-bottom:12px">Light</div>
        <div style="display:grid;grid-template-columns:repeat(2, minmax(0, 1fr));gap:12px">
          {sw(l['ground'],'ground','#F1F1F3')}
          {sw(l['card'],'card','#FCFCFD')}
          {sw(l['well'],'well','#E8E8EB')}
          {sw('#303030','accent','graphite accentLight')}
          {sw('#4A4A4E','bright','bright')}
          {sw('#000000','separator','10%')}
        </div>
      </div>
    </div>

    <div style="display:grid;grid-template-columns:1.25fr 1fr;gap:22px">
      <div class="glass" style="padding:16px 18px">
        <div class="cap" style="padding-bottom:6px">Type — SF Pro, Dynamic Type throughout</div>
        {typ('largeTitle',34,700,'-0.8px','Sessions')}
        {typ('title2',22,600,'-0.4px','What should it work on?')}
        {typ('headline',17,600,'-0.4px','Fix the composer layout')}
        {typ('body',17,400,'-0.4px','A hair test looks for metabolites.')}
        {typ('subheadline',15,400,'-0.2px','Editing · vamp-assistant')}
        {typ('footnote',13,400,'','Starts with the folder you used last.')}
        {typ('caption · sections',11,600,'0.9px','TODAY')}
      </div>

      <div class="glass" style="padding:16px 18px">
        <div class="cap" style="padding-bottom:12px">Glass</div>
        <div class="mono" style="font-size:11px;color:{t['text2']};line-height:19px">
          fill&nbsp;&nbsp;&nbsp;&nbsp;card @ 72%<br>
          blur&nbsp;&nbsp;&nbsp;&nbsp;24 · saturate 1.4<br>
          rim&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;0.75px white @ 13%<br>
          inner&nbsp;&nbsp;&nbsp;top highlight @ 10%<br>
          shadow&nbsp;&nbsp;0 8 22 black @ 46%<br>
          radius&nbsp;&nbsp;18 card · 12 well · 999 pill
        </div>
        <div class="fn" style="margin-top:12px;line-height:17px">Reduce Transparency drops the blur and paints card/well opaque; nothing else changes.</div>
      </div>
    </div>

    <div class="glass" style="padding:16px 18px">
      <div class="cap" style="padding-bottom:14px">Controls</div>
      <div style="display:flex;gap:26px;align-items:center;flex-wrap:wrap">
        <div style="display:flex;flex-direction:column;gap:7px;align-items:center">
          <div style="height:44px;padding:0 26px;border-radius:22px;background:{a};color:#fff;display:flex;align-items:center;font-size:16px;font-weight:600">Start session</div>
          <div class="c2">primary</div>
        </div>
        <div style="display:flex;flex-direction:column;gap:7px;align-items:center">
          <div style="height:44px;padding:0 26px;border-radius:22px;background:{t['well']};color:{t['text3']};display:flex;align-items:center;font-size:16px;font-weight:600">Start session</div>
          <div class="c2">disabled</div>
        </div>
        <div style="display:flex;flex-direction:column;gap:7px;align-items:center">
          <div class="chip" style="height:34px">Steer</div>
          <div class="c2">secondary</div>
        </div>
        <div style="display:flex;flex-direction:column;gap:7px;align-items:center">
          <div style="width:44px;height:44px;border-radius:22px;background:{t['glass']};border:0.75px solid {t['rim']};display:flex;align-items:center;justify-content:center">{ico('gear', br, 20)}</div>
          <div class="c2">glass · 44pt</div>
        </div>
        <div style="display:flex;flex-direction:column;gap:7px;align-items:center">
          <div style="display:flex;gap:5px;align-items:center;height:44px;padding:0 14px;border-radius:14px;background:{t['well']}">{ico('display', br, 18)}<span style="font-size:13px;font-weight:500;color:{t['text2']}">Stream</span></div>
          <div class="c2">pressed</div>
        </div>
        <div style="display:flex;flex-direction:column;gap:7px;align-items:center">
          <div style="display:flex;align-items:center;gap:8px;height:30px">{ico('check', t['text3'], 13, 2.4)}<span class="mono" style="opacity:.82">web search</span><span class="fn" style="color:{t['text3']}">5 results</span></div>
          <div class="c2">ledger row</div>
        </div>
      </div>
    </div>

    <div class="fn" style="line-height:18px">Rules that hold everywhere: the platform owns structure and gestures; the accent is monochrome and only failure is coloured; the engraving sits at 13% dark / 15% light behind every screen and can be switched off in Settings; the assistant's prose never sits in a bubble.</div>
  </div>
</div>
''' + TAIL

open("Foundations.dc.html","w").write(foundations)
print("ok")
