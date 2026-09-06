from kit import head, TAIL, ico
from tokens import DARK as t

a=t['accent']; br=t['bright']
GROUND=t['ground']

def card_row(icon, title, value, detail=None, last=False):
    d = f'<div class="c2" style="margin-top:1px">{detail}</div>' if detail else ''
    return f'''<div class="row">
        <div style="width:26px;height:26px;border-radius:8px;background:{t['glass']};display:flex;align-items:center;justify-content:center;flex:none">{ico(icon, br, 15)}</div>
        <div style="font-size:15px;font-weight:500">{title}</div>
        <div style="flex:1"></div>
        <div style="text-align:right"><div class="sub">{value}</div>{d}</div>
        {ico('chevron', t['text3'], 13, 2)}
      </div>''' + ('' if last else '<div class="div" style="margin-left:14px"></div>')

new_session = head(t) + f'''<div class="screen">
  <div class="atmos"></div>
  <div class="layer">
    <div style="display:flex;align-items:center;padding:12px 16px 14px;border-bottom:0.75px solid {t['sep']}">
      <div class="b" style="color:{br};font-size:16px">Cancel</div>
      <div class="h" style="flex:1;text-align:center">New session</div>
      <div style="width:52px"></div>
    </div>

    <div style="padding:16px 18px 0;display:flex;flex-direction:column;gap:20px">
      <div class="glass">
        <div style="padding:14px;min-height:104px">
          <div class="b" style="color:{t['text3']}">What should it work on?</div>
        </div>
        <div class="div"></div>
        <div style="display:flex;gap:8px;padding:10px 12px;overflow:hidden">
          <div class="chip" style="flex:none">Plan this task</div>
          <div class="chip" style="flex:none">Explain this project</div>
          <div class="chip" style="flex:none">Help me…</div>
        </div>
      </div>

      <div>
        <div class="cap" style="padding:0 2px 8px">Setup</div>
        <div class="glass">
          {card_row('bubble','Works in','Chat only')}
          {card_row('person','Bot','Assistant')}
          {card_row('cpu','Model','Qwen3.5 9B MLX','9B · 4-bit', last=True)}
        </div>
        <div class="fn" style="padding:8px 2px 0">Starts with the folder, bot and model you used last.</div>
      </div>

      <div>
        <div class="cap" style="padding:0 2px 8px">More</div>
        <div class="glass">
          {card_row('brain','Reasoning','Auto')}
          {card_row('box','Sandboxes &amp; keys','', last=True)}
        </div>
      </div>
    </div>

    <div style="flex:1"></div>
    <div style="padding:12px 20px 18px;border-top:0.75px solid {t['sep']};background:{t['glass2']};-webkit-backdrop-filter:blur(24px);backdrop-filter:blur(24px)">
      <div class="fn" style="padding-bottom:8px">Type what you want done.</div>
      <div style="height:50px;border-radius:25px;background:{t['glass']};border:0.75px solid {t['rim']};display:flex;align-items:center;justify-content:center">
        <div class="h" style="color:{t['text3']}">Start session</div>
      </div>
    </div>
  </div>
</div>
''' + TAIL

def bot_card(nm, role, status, active=False):
    dotc = br if active else t['text3']
    return f'''<div class="glass" style="padding:14px;display:flex;flex-direction:column;gap:10px">
      <div style="width:52px;height:52px;border-radius:26px;overflow:hidden;border:0.75px solid {t['rim']}">
        <img src="atmosphere.jpg" alt="" style="width:100%;height:100%;object-fit:cover;filter:grayscale(1) contrast(1.1)">
      </div>
      <div>
        <div class="h">{nm}</div>
        <div class="fn" style="margin-top:2px">{role}</div>
      </div>
      <div style="display:flex;align-items:center;gap:6px">
        <div style="width:6px;height:6px;border-radius:3px;background:{dotc}"></div>
        <div class="c2" style="color:{dotc}">{status}</div>
      </div>
    </div>'''

bots = head(t) + f'''<div class="screen">
  <div class="atmos"></div>
  <div class="layer" style="padding:0 18px">
    <div style="display:flex;align-items:center;justify-content:space-between;padding:14px 0 6px">
      <div class="t1">Bots</div>
      <div class="chip">Done</div>
    </div>
    <div class="sub" style="padding-bottom:20px;line-height:20px">Five specialists on your Mac, each with its own brief.</div>

    <div class="cap" style="padding-bottom:8px">Running now</div>
    <div class="glass" style="padding:13px;display:flex;gap:12px;align-items:flex-start;margin-bottom:20px">
      <div style="width:38px;height:38px;border-radius:19px;overflow:hidden;flex:none;border:0.75px solid {t['rim']}">
        <img src="atmosphere.jpg" alt="" style="width:100%;height:100%;object-fit:cover;filter:grayscale(1)">
      </div>
      <div style="flex:1;min-width:0">
        <div style="display:flex;align-items:center;gap:8px">
          <div style="font-size:15px;font-weight:600">Builder</div>
          <div class="c2" style="color:{br}">Editing</div>
          <div style="flex:1"></div>
          <div style="width:12px;height:12px;border-radius:6px;border:1.6px solid {t['text3']};border-top-color:{br}"></div>
        </div>
        <div class="fn" style="margin-top:3px;line-height:17px">Port the diff viewer to the new ledger rows and keep the mono column aligned.</div>
      </div>
    </div>

    <div class="cap" style="padding-bottom:8px">The team</div>
    <div style="display:grid;grid-template-columns:repeat(2, minmax(0, 1fr));gap:12px">
      {bot_card('Assistant','Balanced assistant','Chat only')}
      {bot_card('Builder','Build and fix','Editing', active=True)}
      {bot_card('Reviewer','Diff and risks','Idle')}
      {bot_card('Navigator','Browser control','Idle')}
    </div>
  </div>
</div>
''' + TAIL

def swatch(c, sel=False):
    ring = ('box-shadow:0 0 0 2px ' + GROUND + ',0 0 0 3.5px ' + br + ';') if sel else ''
    return f'<div style="width:26px;height:26px;border-radius:13px;background:{c};{ring}flex:none"></div>'

settings = head(t) + f'''<div class="screen">
  <div class="atmos"></div>
  <div class="layer" style="padding:0 20px">
    <div style="display:flex;align-items:center;justify-content:space-between;padding:14px 0 18px">
      <div class="t1">Settings</div>
      <div class="b" style="color:{br};font-size:16px">Done</div>
    </div>

    <div class="cap" style="padding-bottom:8px">Appearance</div>
    <div class="div"></div>
    <div style="padding:12px 0">
      <div style="display:flex;gap:2px;padding:2px;border-radius:9px;background:{t['well']}">
        <div style="flex:1;text-align:center;padding:7px 0;font-size:13px;font-weight:500;color:{t['text2']}">System</div>
        <div style="flex:1;text-align:center;padding:7px 0;font-size:13px;font-weight:500;color:{t['text2']}">Light</div>
        <div style="flex:1;text-align:center;padding:7px 0;font-size:13px;font-weight:600;border-radius:7px;background:{t['card']};box-shadow:0 1px 3px {t['shadow']}">Dark</div>
      </div>
    </div>
    <div class="div"></div>
    <div style="display:flex;align-items:center;gap:10px;min-height:56px">
      {swatch('#686868', sel=True)}{swatch('#4A4A4E')}{swatch('#445677')}{swatch('#487A5C')}{swatch('#B05E3C')}{swatch('#B03055')}{swatch('#3F7BC4')}
    </div>
    <div class="div"></div>
    <div style="display:flex;align-items:center;gap:12px;min-height:56px">
      <div style="flex:1;font-size:16px">Background image</div>
      <div style="width:51px;height:31px;border-radius:16px;background:{br};display:flex;align-items:center;justify-content:flex-end;padding:2px;flex:none">
        <div style="width:27px;height:27px;border-radius:14px;background:#fff;box-shadow:0 1px 3px rgba(0,0,0,.3)"></div>
      </div>
    </div>
    <div class="div"></div>
    <div class="fn" style="padding:9px 0 0;line-height:17px">The engraved atmosphere sits behind every screen. Off replaces it with a plain ground.</div>

    <div class="cap" style="padding:24px 0 8px">Mac</div>
    <div class="div"></div>
    <div style="display:flex;align-items:center;gap:13px;min-height:56px">
      {ico('display', br, 20)}<div style="font-size:16px">Computer</div><div style="flex:1"></div>
      <div class="sub">vamp-mini</div>{ico('chevron', t['text3'], 13, 2)}
    </div>
    <div class="div"></div>
    <div style="display:flex;align-items:center;gap:13px;min-height:56px">
      {ico('pulse', br, 20)}<div style="font-size:16px">Diagnostics</div><div style="flex:1"></div>
      {ico('chevron', t['text3'], 13, 2)}
    </div>
    <div class="div"></div>

    <div class="cap" style="padding:24px 0 8px">About</div>
    <div class="div"></div>
    <div style="display:flex;align-items:center;gap:13px;min-height:56px">
      <div style="width:34px;height:34px;border-radius:9px;overflow:hidden;flex:none;border:0.75px solid {t['rim']}">
        <img src="atmosphere.jpg" alt="" style="width:100%;height:100%;object-fit:cover;filter:grayscale(1)">
      </div>
      <div style="flex:1"><div style="font-size:16px">Vamp Assistant</div>
      <div class="c2" style="margin-top:1px">0.1.37 · build 72</div></div>
    </div>
    <div class="div"></div>
  </div>
</div>
''' + TAIL

if __name__ == "__main__":
    open("NewSession.dc.html","w").write(new_session)
    open("Bots.dc.html","w").write(bots)
    open("Settings.dc.html","w").write(settings)
    print("ok")
