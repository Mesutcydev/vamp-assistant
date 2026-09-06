from kit import head, TAIL, ico
from tokens import DARK as t

a=t['accent']; br=t['bright']

def portrait(size, ring=True):
    return f'''<div style="width:{size}px;height:{size}px;border-radius:{size//2}px;overflow:hidden;flex:none;border:0.75px solid {t['rim']}">
      <img src="atmosphere.jpg" alt="" style="width:100%;height:100%;object-fit:cover;filter:grayscale(1) contrast(1.1)"></div>'''

# ---------------------------------------------------------------- Bots A
def bots_dispatch():
    def flight(nm, phase, pct, elapsed):
        return f'''<div style="display:flex;align-items:center;gap:11px;padding:11px 14px">
          {portrait(30)}
          <div style="flex:1;min-width:0">
            <div style="display:flex;align-items:baseline;gap:7px">
              <div style="font-size:15px;font-weight:600">{nm}</div>
              <div class="c2" style="color:{br}">{phase}</div>
              <div style="flex:1"></div>
              <div class="c2" style="font-variant-numeric:tabular-nums">{elapsed}</div>
            </div>
            <div style="height:2px;border-radius:1px;background:{t['sep']};margin-top:7px">
              <div style="height:2px;border-radius:1px;background:{br};width:{pct}%"></div>
            </div>
          </div>
        </div>'''
    def face(nm):
        return f'''<div style="display:flex;flex-direction:column;align-items:center;gap:6px;width:62px;flex:none">
          {portrait(48)}<div class="c2" style="color:{t['text2']}">{nm}</div></div>'''
    return head(t) + f'''<div class="screen">
  <div class="atmos"></div>
  <div class="layer" style="padding:0 18px">
    <div style="display:flex;align-items:center;justify-content:space-between;padding:14px 0 14px">
      <div class="t1">Bots</div><div class="chip">Done</div>
    </div>

    <div class="glass" style="padding:16px 14px 10px">
      <div class="cap" style="padding-bottom:10px">Give the team a job</div>
      <div class="b" style="color:{t['text3']};font-size:19px;line-height:26px;min-height:78px">Describe the outcome you want…</div>
      <div class="div" style="margin:0 -14px"></div>
      <div style="display:flex;align-items:center;gap:8px;padding-top:10px">
        <div style="display:flex;gap:2px;padding:2px;border-radius:9px;background:{t['glass']}">
          <div style="padding:5px 12px;font-size:12px;font-weight:600;border-radius:7px;background:{t['card']}">Auto</div>
          <div style="padding:5px 12px;font-size:12px;font-weight:500;color:{t['text2']}">Pick</div>
        </div>
        <div class="chip" style="padding:5px 11px;font-size:12px">{ico('cpu', t['text2'], 13)} GPT-5</div>
        <div style="flex:1"></div>
        <div style="width:34px;height:34px;border-radius:17px;background:{a};display:flex;align-items:center;justify-content:center">{ico('arrowup','#fff',18,2.2)}</div>
      </div>
    </div>

    <div class="cap" style="padding:22px 2px 8px">In flight</div>
    <div class="glass" style="padding:2px 0">
      {flight('Builder','Editing',62,'38s')}
      <div class="div" style="margin-left:55px"></div>
      {flight('Reviewer','Reading diff',24,'1m 12s')}
    </div>

    <div class="cap" style="padding:22px 2px 10px">The team</div>
    <div style="display:flex;gap:10px;overflow:hidden">
      {face('Assistant')}{face('Builder')}{face('Reviewer')}{face('Navigator')}{face('Research')}
    </div>
    <div class="fn" style="padding-top:12px;line-height:17px">Tap a face to read its brief, chat with it, or start a run yourself.</div>
  </div>
</div>
''' + TAIL

# ---------------------------------------------------------------- Bots B
def bots_directory():
    def row(nm, role, status, active=False, last=False):
        c = br if active else t['text3']
        trail = f'<div class="fn" style="color:{c}">{status}</div>' if status else ''
        return f'''<div style="display:flex;align-items:center;gap:13px;padding:11px 14px">
          {portrait(46)}
          <div style="flex:1;min-width:0">
            <div class="h">{nm}</div>
            <div class="sub" style="margin-top:2px">{role}</div>
          </div>
          {trail}
          {ico('chevron', t['text3'], 14, 2)}
        </div>''' + ('' if last else '<div class="div" style="margin-left:73px"></div>')
    return head(t) + f'''<div class="screen">
  <div class="atmos"></div>
  <div class="layer" style="padding:0 18px">
    <div style="display:flex;align-items:center;justify-content:space-between;padding:14px 0 6px">
      <div class="t1">Bots</div><div class="chip">Done</div>
    </div>
    <div class="sub" style="padding-bottom:18px">Five specialists on your Mac, each with its own brief.</div>

    <div class="cap" style="padding-bottom:8px">Running</div>
    <div class="glass" style="padding:2px 0;margin-bottom:20px">
      <div style="display:flex;align-items:center;gap:13px;padding:11px 14px">
        {portrait(46)}
        <div style="flex:1;min-width:0">
          <div class="h">Builder</div>
          <div class="fn" style="margin-top:2px;color:{br}">Editing · 2 files · 38s</div>
        </div>
        <div style="width:14px;height:14px;border-radius:7px;border:1.8px solid {t['text3']};border-top-color:{br}"></div>
      </div>
    </div>

    <div class="cap" style="padding-bottom:8px">The team</div>
    <div class="glass" style="padding:2px 0">
      {row('Assistant','Balanced assistant','Chat only')}
      {row('Builder','Build and fix','Editing', active=True)}
      {row('Reviewer','Diff and risks','Idle')}
      {row('Navigator','Browser control','Idle')}
      {row('Researcher','Sources and synthesis','Idle', last=True)}
    </div>

    <div class="glass" style="margin-top:20px">
      <div class="row">
        <div style="width:26px;height:26px;border-radius:8px;background:{t['glass']};display:flex;align-items:center;justify-content:center;flex:none">{ico('people', br, 15)}</div>
        <div style="flex:1"><div style="font-size:15px;font-weight:500">Delegate to the team</div>
        <div class="c2" style="margin-top:1px">They divide one outcome between them</div></div>
        {ico('chevron', t['text3'], 13, 2)}
      </div>
    </div>
  </div>
</div>
''' + TAIL

# ------------------------------------------------------- New session A
def new_composer():
    def starter(txt):
        return f'''<div style="display:flex;align-items:center;gap:10px;padding:12px 2px;border-bottom:0.75px solid {t['sep']}">
          <div class="b" style="flex:1;color:{t['text2']};font-size:16px">{txt}</div>
          {ico('arrowup', t['text3'], 15, 2)}
        </div>'''
    def pill(icon, txt):
        return f'''<div class="chip" style="padding:7px 12px">{ico(icon, t['text2'], 14)} {txt} {ico('chevdown', t['text3'], 12, 2.2)}</div>'''
    return head(t) + f'''<div class="screen">
  <div class="atmos"></div>
  <div class="layer" style="padding:0 18px">
    <div style="display:flex;align-items:center;padding:14px 0 22px">
      <div class="b" style="color:{br};font-size:16px">Cancel</div>
    </div>

    <div class="t1" style="font-size:30px;line-height:36px;color:{t['text3']};padding-right:30px">What should it<br>work on?</div>

    <div style="display:flex;flex-wrap:wrap;gap:8px;padding:26px 0 0">
      {pill('bubble','Chat only')}{pill('person','Assistant')}{pill('cpu','Qwen3.5 9B')}
    </div>

    <div style="padding:30px 0 0">
      <div class="cap" style="padding-bottom:4px">Or start from</div>
      {starter('Plan this task')}
      {starter('Explain this project')}
      {starter('Review my changes')}
    </div>

    <div style="flex:1"></div>
    <div style="padding:0 0 20px;display:flex;align-items:center;gap:10px">
      <div style="flex:1;height:46px;border-radius:23px;background:{t['glass']};border:0.75px solid {t['rim']};display:flex;align-items:center;padding:0 6px 0 16px">
        <div class="b" style="flex:1;color:{t['text3']};font-size:16px">Type to start…</div>
        <div style="width:36px;height:36px;border-radius:18px;background:{t['well']};display:flex;align-items:center;justify-content:center">{ico('arrowup', t['text3'], 18, 2.2)}</div>
      </div>
    </div>
  </div>
</div>
''' + TAIL

# ------------------------------------------------------- New session B
def new_modes():
    def seg(txt, on=False):
        return (f'<div style="flex:1;text-align:center;padding:8px 0;font-size:13px;font-weight:600;border-radius:8px;background:{t["card"]};box-shadow:0 1px 3px {t["shadow"]}">{txt}</div>'
                if on else f'<div style="flex:1;text-align:center;padding:8px 0;font-size:13px;font-weight:500;color:{t["text2"]}">{txt}</div>')
    def line(icon, title, value, last=False):
        return f'''<div style="display:flex;align-items:center;gap:11px;padding:0 14px;min-height:48px">
          {ico(icon, br, 16)}
          <div style="font-size:15px;font-weight:500">{title}</div>
          <div style="flex:1"></div>
          <div class="sub">{value}</div>{ico('chevron', t['text3'], 13, 2)}
        </div>''' + ('' if last else '<div class="div" style="margin-left:14px"></div>')
    return head(t) + f'''<div class="screen">
  <div class="atmos"></div>
  <div class="layer">
    <div style="flex:1"></div>
    <div class="glass" style="border-radius:26px 26px 0 0;border-bottom:none;padding:10px 0 0">
      <div style="width:36px;height:5px;border-radius:3px;background:{t['sep']};margin:0 auto 14px"></div>
      <div style="padding:0 18px 16px">
        <div class="h" style="font-size:20px;padding-bottom:14px">New session</div>

        <div style="display:flex;gap:2px;padding:2px;border-radius:10px;background:{t['glass']}">
          {seg('Chat', on=True)}{seg('In a folder')}{seg('Bot computer')}
        </div>

        <div style="padding:16px 0 0">
          <div class="glass" style="padding:14px;min-height:112px;border-radius:16px">
            <div class="b" style="color:{t['text3']}">What should it work on?</div>
          </div>
        </div>

        <div style="display:flex;gap:8px;padding:12px 0 0;overflow:hidden">
          <div class="chip" style="flex:none">Plan this task</div>
          <div class="chip" style="flex:none">Explain this project</div>
        </div>

        <div class="glass" style="margin-top:18px;border-radius:16px">
          {line('person','Bot','Assistant')}
          {line('cpu','Model','Qwen3.5 9B MLX', last=True)}
        </div>

        <div style="height:50px;border-radius:25px;background:{t['well']};display:flex;align-items:center;justify-content:center;margin-top:18px">
          <div class="h" style="color:{t['text3']}">Start session</div>
        </div>
        <div class="fn" style="text-align:center;padding-top:9px">Type what you want done.</div>
      </div>
    </div>
  </div>
</div>
''' + TAIL

if __name__ == "__main__":
    open("BotsDispatch.dc.html","w").write(bots_dispatch())
    open("BotsDirectory.dc.html","w").write(bots_directory())
    open("NewSessionComposer.dc.html","w").write(new_composer())
    open("NewSessionModes.dc.html","w").write(new_modes())
    print("ok")
