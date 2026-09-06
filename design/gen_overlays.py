from kit import head, TAIL, ico
from tokens import DARK as t

a=t['accent']; br=t['bright']

def label(txt):
    return f'<div class="cap" style="padding:0 0 8px">{txt}</div>'

def pop_row(icon, title, detail, last=False):
    return f'''<div style="display:flex;align-items:center;gap:11px;padding:0 14px;min-height:46px">
      <div style="width:26px;height:26px;border-radius:8px;background:{t['glass']};display:flex;align-items:center;justify-content:center;flex:none">{ico(icon, t['text2'], 14)}</div>
      <div style="min-width:0">
        <div style="font-size:15px;font-weight:500">{title}</div>
        <div class="c2" style="margin-top:1px">{detail}</div>
      </div>
    </div>''' + ('' if last else '<div class="div" style="margin-left:48px"></div>')

def menu_row(txt, icon, destructive=False, last=False):
    c = t['red'] if destructive else t['text']
    return f'''<div style="display:flex;align-items:center;gap:12px;padding:0 14px;min-height:44px;color:{c}">
      <div style="flex:1;font-size:16px">{txt}</div>{ico(icon, c, 17)}
    </div>''' + ('' if last else f'<div style="height:0.75px;background:{t["sep"]}"></div>')

overlays = head(t, 390, 1120) + f'''<div class="screen" style="height:1120px">
  <div class="atmos"></div>
  <div class="layer" style="padding:20px 18px;gap:26px">

    <div>
      {label('Commands popover — anchored to the + ')}
      <div style="display:flex;justify-content:flex-start">
        <div style="position:relative">
          <div class="glass" style="width:292px;border-radius:16px;padding:4px 0 8px;overflow:hidden">
            <div class="cap" style="padding:10px 14px 4px;font-size:10px">Workspace</div>
            {pop_row('diff','Git diff','Review uncommitted changes')}
            {pop_row('clip','@context','Use the current workspace and chat', last=True)}
            <div class="cap" style="padding:12px 14px 4px;font-size:10px">Browser control</div>
            {pop_row('safari','Open page','Navigate with browser control')}
            {pop_row('doc','Read page','Inspect the current page')}
            {pop_row('camera','Screenshot','Capture and analyze the page', last=True)}
          </div>
          <div style="width:14px;height:14px;background:{t['glass2']};border-left:0.75px solid {t['rim']};border-bottom:0.75px solid {t['rim']};transform:rotate(-45deg);margin:-7px 0 0 24px"></div>
        </div>
      </div>
      <div style="display:flex;gap:10px;margin-top:8px">
        <div style="width:32px;height:32px;border-radius:16px;background:{t['glass']};border:0.75px solid {t['rim']};display:flex;align-items:center;justify-content:center">{ico('plus', t['text2'], 17)}</div>
        <div style="flex:1;height:38px;border-radius:19px;background:{t['glass']};border:0.75px solid {t['rim']};display:flex;align-items:center;padding:0 14px" class="sub">Message your assistant…</div>
      </div>
    </div>

    <div>
      {label('Session menu — long press a row')}
      <div class="glass" style="width:250px;border-radius:14px;padding:4px 0">
        {menu_row('Rename','pencil')}
        {menu_row('Share transcript','share')}
        {menu_row('Delete','trash', destructive=True, last=True)}
      </div>
    </div>

    <div>
      {label('Model picker — sheet')}
      <div class="glass" style="border-radius:20px;padding:10px 0 6px">
        <div style="width:36px;height:5px;border-radius:3px;background:{t['sep']};margin:0 auto 12px"></div>
        <div style="display:flex;align-items:center;padding:0 16px 10px">
          <div class="h" style="flex:1">Model</div>
          <div class="chip" style="padding:5px 12px">On this Mac</div>
        </div>
        <div class="div"></div>
        <div style="display:flex;align-items:center;gap:12px;padding:0 16px;min-height:52px">
          <div style="flex:1"><div style="font-size:15px;font-weight:500">Qwen3.5 9B MLX</div><div class="c2" style="margin-top:1px">9B · 4-bit · local</div></div>
          {ico('check', br, 17, 2.2)}
        </div>
        <div class="div" style="margin-left:16px"></div>
        <div style="display:flex;align-items:center;gap:12px;padding:0 16px;min-height:52px">
          <div style="flex:1"><div style="font-size:15px;font-weight:500">GPT-5</div><div class="c2" style="margin-top:1px">API · reasoning</div></div>
        </div>
      </div>
    </div>

    <div>
      {label('Destructive confirm — alert')}
      <div style="display:flex;justify-content:center">
        <div class="glass" style="width:270px;border-radius:14px;text-align:center;padding:18px 16px 0">
          <div class="h">Delete this chat?</div>
          <div class="fn" style="margin-top:6px;line-height:17px">“Port the diff viewer” is removed from your Mac. This cannot be undone.</div>
          <div style="height:0.75px;background:{t['sep']};margin:16px -16px 0"></div>
          <div style="display:flex;min-height:44px;align-items:center">
            <div style="flex:1;font-size:17px;color:{t['red']};font-weight:600">Delete</div>
            <div style="width:0.75px;align-self:stretch;background:{t['sep']}"></div>
            <div style="flex:1;font-size:17px;color:{br}">Cancel</div>
          </div>
        </div>
      </div>
    </div>

  </div>
</div>
''' + TAIL

def state(title, body):
    return f'''<div>
      {label(title)}
      {body}
    </div>'''

composer_idle = f'''<div style="display:flex;gap:10px;align-items:center">
  <div style="width:32px;height:32px;border-radius:16px;background:{t['glass']};border:0.75px solid {t['rim']};display:flex;align-items:center;justify-content:center">{ico('plus', t['text2'], 17)}</div>
  <div style="flex:1;height:38px;border-radius:19px;background:{t['glass']};border:0.75px solid {t['rim']};display:flex;align-items:center;padding:0 6px 0 14px">
    <div class="sub" style="flex:1;font-size:16px">Message your assistant…</div>
    <div style="width:30px;height:30px;border-radius:15px;background:{t['glass']};display:flex;align-items:center;justify-content:center;opacity:.5">{ico('arrowup', t['text2'], 17, 2)}</div>
  </div>
</div>'''

composer_running = f'''<div style="display:flex;gap:10px;align-items:center">
  <div style="width:32px;height:32px;border-radius:16px;background:{t['glass']};border:0.75px solid {t['rim']};display:flex;align-items:center;justify-content:center">{ico('plus', t['text2'], 17)}</div>
  <div style="flex:1;height:38px;border-radius:19px;background:{t['glass']};border:0.75px solid {t['rim']};display:flex;align-items:center;gap:8px;padding:0 6px 0 14px">
    <div class="b" style="flex:1;font-size:16px">Also check the light mode</div>
    <div class="chip" style="padding:4px 11px;font-size:12px">Steer</div>
    <div style="width:30px;height:30px;border-radius:15px;background:{a};display:flex;align-items:center;justify-content:center">{ico('plus', '#fff', 16, 2.2)}</div>
  </div>
</div>'''

chat_states = head(t, 390, 1180) + f'''<div class="screen" style="height:1180px">
  <div class="atmos"></div>
  <div class="layer" style="padding:20px 18px;gap:24px">

    {state('Idle — one field, one action', composer_idle)}

    {state('Running — Send queues, Steer redirects', composer_running)}

    {state('Run bar — phase and the only Stop', f"""
      <div style="display:flex;align-items:center;gap:9px;padding:6px 4px">
        <div style="width:13px;height:13px;border-radius:7px;border:1.6px solid {t['text3']};border-top-color:{br}"></div>
        <div class="fn">Editing · 2 files · 38s</div>
        <div style="flex:1"></div>
        <div class="chip" style="padding:5px 14px">{ico('stop', t['text'], 13, 2)} Stop</div>
      </div>""")}

    {state('Approval — the model asks before it acts', f"""
      <div class="glass" style="padding:14px">
        <div style="display:flex;gap:10px;align-items:flex-start">
          {ico('box', br, 18)}
          <div style="flex:1">
            <div style="font-size:15px;font-weight:600">Run a shell command?</div>
            <div class="mono" style="margin-top:8px;background:{t['glass']};border-radius:10px;padding:9px 11px;font-size:12px;color:{t['text2']}">swift test --filter TranscriptItemTests</div>
          </div>
        </div>
        <div style="display:flex;gap:8px;margin-top:12px">
          <div style="flex:1;height:36px;border-radius:18px;background:{a};color:#fff;display:flex;align-items:center;justify-content:center;font-size:15px;font-weight:600">Allow</div>
          <div style="flex:1;height:36px;border-radius:18px;background:{t['glass']};border:0.75px solid {t['rim']};display:flex;align-items:center;justify-content:center;font-size:15px">Not now</div>
        </div>
      </div>""")}

    {state('Question — the model needs one answer', f"""
      <div class="glass" style="padding:14px">
        <div style="font-size:15px;font-weight:600">Which target should I build?</div>
        <div style="display:flex;gap:8px;margin-top:11px;flex-wrap:wrap">
          <div class="chip">BeetCodeRemoteIOS</div>
          <div class="chip">BeetCode</div>
          <div class="chip">Both</div>
        </div>
      </div>""")}

    {state('Queued — it waits its turn, and says so', f"""
      <div style="display:flex;align-items:center;gap:9px;padding:10px 12px;border-radius:12px;background:{t['glass']}">
        {ico('clip', t['text3'], 15)}
        <div class="fn" style="flex:1">Queued · “Also check the light mode”</div>
        {ico('xmark', t['text3'], 14, 2)}
      </div>""")}

    {state('Failed — the run kept its trace', f"""
      <div class="glass" style="padding:13px;border-color:rgba(212,105,95,0.35)">
        <div style="display:flex;gap:9px;align-items:flex-start">
          {ico('xmark', t['red'], 15, 2.2)}
          <div style="flex:1">
            <div class="fn" style="color:{t['text']};font-weight:600">The model stopped responding</div>
            <div class="fn" style="margin-top:3px;line-height:17px">The transcript is kept. Start a new chat or switch model.</div>
          </div>
        </div>
      </div>""")}

  </div>
</div>
''' + TAIL

if __name__ == "__main__":
    open("Overlays.dc.html","w").write(overlays)
    open("ChatStates.dc.html","w").write(chat_states)
    print("ok")
