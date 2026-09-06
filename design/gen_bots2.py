from kit import head, TAIL, ico, MONO
from tokens import DARK as t

a=t['accent']; br=t['bright']

# ------------------------------------------------------------ A: plain list
def bots_list():
    def row(nm, role, status, icon, active=False, last=False):
        c = br if active else t['text3']
        return f'''<div style="display:flex;align-items:center;gap:13px;min-height:58px;padding:0 2px">
          <div style="width:22px;flex:none;display:flex;justify-content:center">{ico(icon, br if active else t['text2'], 20)}</div>
          <div style="flex:1;min-width:0">
            <div class="h">{nm}</div>
            <div class="fn" style="margin-top:2px">{role}</div>
          </div>
          <div class="fn" style="color:{c}">{status}</div>
          {ico('chevron', t['text3'], 13, 2)}
        </div>''' + ('' if last else f'<div class="div" style="margin-left:35px"></div>')
    return head(t) + f'''<div class="screen">
  <div class="atmos"></div>
  <div class="layer" style="padding:0 20px">
    <div style="display:flex;align-items:center;justify-content:space-between;padding:14px 0 18px">
      <div class="t1">Bots</div>
      <div class="b" style="color:{br};font-size:16px">Done</div>
    </div>

    <div class="cap" style="padding-bottom:2px">Running</div>
    <div class="div"></div>
    <div style="display:flex;align-items:center;gap:13px;min-height:58px;padding:0 2px">
      <div style="width:22px;flex:none;display:flex;justify-content:center">{ico('hammer', br, 20)}</div>
      <div style="flex:1;min-width:0">
        <div class="h">Builder</div>
        <div class="fn" style="margin-top:2px;color:{br}">Editing · 2 files · 38s</div>
      </div>
      <div class="chip" style="padding:5px 13px;font-size:13px">Stop</div>
    </div>
    <div class="div"></div>

    <div class="cap" style="padding:26px 0 2px">Team</div>
    <div class="div"></div>
    {row('Assistant','Balanced, no brief','Chat only','bubble')}
    {row('Builder','Builds and fixes','Editing','hammer', active=True)}
    {row('Reviewer','Diffs and risks','Idle','diff')}
    {row('Navigator','Drives the browser','Idle','compass')}
    {row('Researcher','Sources and synthesis','Idle','loupe', last=True)}
    <div class="div"></div>

    <div class="cap" style="padding:26px 0 2px">Together</div>
    <div class="div"></div>
    <div style="display:flex;align-items:center;gap:13px;min-height:58px;padding:0 2px">
      <div style="width:22px;flex:none;display:flex;justify-content:center">{ico('people', t['text2'], 20)}</div>
      <div style="flex:1">
        <div class="h">Delegate one outcome</div>
        <div class="fn" style="margin-top:2px">They divide the work between them</div>
      </div>
      {ico('chevron', t['text3'], 13, 2)}
    </div>
    <div class="div"></div>
  </div>
</div>
''' + TAIL

# --------------------------------------------------------- B: console ledger
def bots_console():
    def line(nm, state, meta, active=False, last=False):
        mark = (f'<div style="width:6px;height:6px;border-radius:3px;background:{br};flex:none"></div>'
                if active else '<div style="width:6px;flex:none"></div>')
        c = br if active else t['text3']
        return f'''<div style="display:flex;align-items:center;gap:10px;min-height:44px">
          {mark}
          <div class="mono" style="width:104px;flex:none;font-size:14px;color:{t['text']}">{nm}</div>
          <div class="mono" style="flex:1;font-size:13px;color:{c}">{state}</div>
          <div class="mono" style="font-size:12px;color:{t['text3']};font-variant-numeric:tabular-nums">{meta}</div>
        </div>''' + ('' if last else '<div class="div" style="margin-left:16px"></div>')
    return head(t) + f'''<div class="screen">
  <div class="atmos"></div>
  <div class="layer" style="padding:0 20px">
    <div style="display:flex;align-items:center;justify-content:space-between;padding:14px 0 20px">
      <div class="t1">Bots</div>
      <div class="b" style="color:{br};font-size:16px">Done</div>
    </div>

    <div style="display:flex;align-items:center;gap:10px;padding-bottom:6px">
      <div style="width:6px"></div>
      <div class="cap" style="width:104px;flex:none;font-size:10px">Bot</div>
      <div class="cap" style="flex:1;font-size:10px">State</div>
      <div class="cap" style="font-size:10px">Last</div>
    </div>
    <div class="div"></div>
    {line('assistant','chat only','—')}
    {line('builder','editing · 2 files','38s', active=True)}
    {line('reviewer','idle','2h')}
    {line('navigator','idle','yesterday')}
    {line('researcher','idle','3d', last=True)}
    <div class="div" style="margin-left:16px"></div>

    <div style="padding:14px 16px 0">
      <div class="fn" style="line-height:17px">Tap a line for its brief, a chat, or a run. Long-press to stop one.</div>
    </div>

    <div style="flex:1"></div>

    <div style="padding-bottom:20px">
      <div class="cap" style="padding-bottom:8px">Delegate</div>
      <div style="display:flex;align-items:center;gap:8px;height:44px;border-radius:12px;background:{t['glass']};border:0.75px solid {t['rim']};padding:0 6px 0 14px">
        <div class="mono" style="flex:1;font-size:13px;color:{t['text3']}">describe an outcome…</div>
        <div class="chip" style="padding:5px 10px;font-size:12px">{ico('cpu', t['text2'], 12)} GPT-5</div>
        <div style="width:32px;height:32px;border-radius:16px;background:{a};display:flex;align-items:center;justify-content:center">{ico('arrowup','#fff',16,2.2)}</div>
      </div>
      <div class="fn" style="padding-top:9px;line-height:17px">One outcome, split between whichever bots it needs.</div>
    </div>
  </div>
</div>
''' + TAIL

if __name__ == "__main__":
    open("BotsList.dc.html","w").write(bots_list())
    print("ok")
