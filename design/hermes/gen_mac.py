from kit import head, TAIL, ico, LIGHT, SERIF

t = LIGHT

def mac():
    def sidebar_row(name, meta, selected=False):
        bg = f'background:{t["raised"]};' if selected else ''
        return f'''<div style="{bg}padding:11px 14px;border-radius:8px;display:flex;align-items:center;gap:10px">
          <div style="flex:1;min-width:0">
            <div style="font-size:13.5px;letter-spacing:-0.1px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">{name}</div>
            <div class="c2" style="margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">{meta}</div>
          </div>
        </div>'''
    def step(name, meta):
        return f'''<div style="display:flex;align-items:center;gap:10px;min-height:30px">
          {ico('check', t['ink3'], 12, 1.6)}
          <div class="mono" style="color:{t['ink2']}">{name}</div>
          <div class="c2">{meta}</div>
        </div>'''
    return head(t, 1280, 820) + f'''<div class="screen" style="width:1280px;height:820px">
  <div class="layer" style="flex-direction:row">

    <div style="width:250px;border-right:1px solid {t['rule']};display:flex;flex-direction:column;padding:0 10px">
      <div style="padding:16px 14px 12px">
        <div class="t2" style="font-size:19px">Vamp</div>
      </div>
      <div class="label" style="padding:10px 14px 6px">Today</div>
      {sidebar_row('Fix the composer layout','Editing · vamp-assistant', selected=True)}
      {sidebar_row('Audit the pairing flow','8 messages')}
      <div class="label" style="padding:18px 14px 6px">Yesterday</div>
      {sidebar_row('Explain the checkpoint format','31 messages')}
      {sidebar_row('Port the diff viewer','forgesign · 112 messages')}
      <div style="flex:1"></div>
      <div style="padding:12px 14px 16px;display:flex;align-items:center;gap:10px">
        <div class="dot" style="background:#3F8A52"></div>
        <div class="c2" style="flex:1">vamp-mini</div>
        {ico('gear', t['ink3'], 16)}
      </div>
    </div>

    <div style="flex:1;display:flex;flex-direction:column">
      <div class="glass" style="border-bottom:1px solid {t['rule']};padding:13px 26px;display:flex;align-items:center;gap:14px">
        <div class="t2" style="font-size:16px;flex:1">Fix the composer layout</div>
        <div class="c2">Editing · GPT-5 · vamp-assistant</div>
        {ico('dots', t['ink2'], 18)}
      </div>

      <div style="flex:1;padding:34px 0;overflow:hidden">
        <div style="max-width:720px;margin:0 auto;display:flex;flex-direction:column;gap:26px">
          <div style="display:flex;justify-content:flex-end">
            <div class="body" style="max-width:70%;padding:12px 16px;border-radius:18px;background:{t['raised']};border:1px solid {t['rule']}">The composer buttons shift when I type — make the bar stop moving.</div>
          </div>

          <div class="body">The Steer button joins the same row as Send, so the stack re-lays out the moment a draft exists. Pinning the trailing group fixes it.</div>

          <div style="border-left:1px solid {t['rule2']};padding-left:16px">
            {step('read file','RemoteComposerView.swift — 166 lines')}
            {step('edit file','RemoteComposerView.swift +18 −4')}
          </div>

          <div>
            <div class="label" style="padding-bottom:10px">Plan · 2 of 4</div>
            <div class="rule"></div>
            <div style="display:flex;gap:12px;align-items:baseline;padding:10px 0"><div style="width:14px">{ico('check', t['ink3'], 12, 1.8)}</div><div class="sub" style="text-decoration:line-through">Read the composer and its callers</div></div>
            <div class="rule" style="margin-left:26px"></div>
            <div style="display:flex;gap:12px;align-items:baseline;padding:10px 0"><div style="width:14px">{ico('check', t['ink3'], 12, 1.8)}</div><div class="sub" style="text-decoration:line-through">Reproduce the layout shift</div></div>
            <div class="rule" style="margin-left:26px"></div>
            <div style="display:flex;gap:12px;align-items:baseline;padding:10px 0"><div style="width:14px"><div class="dot" style="margin-top:6px"></div></div><div class="body" style="font-size:15px">Pin the trailing group</div></div>
            <div class="rule" style="margin-left:26px"></div>
            <div style="display:flex;gap:12px;align-items:baseline;padding:10px 0"><div style="width:14px"><div style="width:5px;height:5px;border-radius:3px;border:1px solid {t['ink3']};margin-top:6px"></div></div><div class="sub">Run the iOS tests</div></div>
          </div>

          <div style="border:1px solid {t['rule']};border-radius:14px">
            <div style="padding:16px 18px">
              <div style="display:flex;align-items:center;gap:9px">
                {ico('box', t['ink2'], 15)}
                <div style="font-size:14px;font-weight:600">Approval needed</div>
                <div style="flex:1"></div>
                <div class="mono" style="color:{t['ink3']}">shell</div>
              </div>
              <div class="sub" style="margin-top:9px;color:{t['ink']}">Run the iOS test target and report the failures.</div>
              <div class="mono" style="margin-top:11px;padding:10px 12px;border-radius:8px;background:{t['raised']};border:1px solid {t['rule']};color:{t['ink2']}">swift test --filter TranscriptItemTests</div>
            </div>
            <div class="rule"></div>
            <div style="padding:12px 18px;display:flex;gap:10px">
              <div style="padding:9px 22px;border-radius:20px;background:{t['accent']};color:#fff;font-size:14px;font-weight:600">Allow once</div>
              <div style="padding:9px 22px;border-radius:20px;border:1px solid {t['rule2']};font-size:14px;font-weight:600">Not now</div>
            </div>
          </div>
        </div>
      </div>

      <div class="glass" style="border-top:1px solid {t['rule']};padding:16px 0">
        <div style="max-width:720px;margin:0 auto;display:flex;align-items:center;gap:14px;padding:0 4px">
          {ico('plus', t['ink2'], 20)}
          <div class="sub" style="flex:1">Message your assistant…</div>
          <div class="c2">⌘↩ to send</div>
          <div style="width:34px;height:34px;border-radius:18px;background:{t['accent']};display:flex;align-items:center;justify-content:center">{ico('arrowup','#fff',17,1.6)}</div>
        </div>
      </div>
    </div>
  </div>
</div>
''' + TAIL

def foundations():
    def sw(hexv, name, note):
        return f'''<div style="display:flex;align-items:center;gap:12px">
          <div style="width:38px;height:38px;border-radius:6px;background:{hexv};border:1px solid {t['rule']}"></div>
          <div><div style="font-size:13px;font-weight:600">{name}</div>
          <div class="mono" style="color:{t['ink3']};margin-top:2px">{note}</div></div>
        </div>'''
    def typ(nm, cls, sample, spec):
        return f'''<div style="display:flex;align-items:baseline;gap:16px;padding:9px 0;border-bottom:1px solid {t['rule']}">
          <div class="mono" style="width:150px;flex:none;color:{t['ink3']}">{spec}</div>
          <div class="{cls}">{sample}</div>
        </div>'''
    return head(t, 980, 1180) + f'''<div class="screen" style="width:980px;height:1180px">
  <div class="layer" style="padding:34px 40px;gap:28px;overflow:hidden">
    <div>
      <div class="t1">Paper, ink, one orange</div>
      <div class="sub" style="margin-top:8px;max-width:640px">Restraint is the system. Two grounds, three ink tiers, one rule weight, one accent — spent once per screen, never twice. Nothing is boxed that does not have to be.</div>
    </div>

    <div style="display:grid;grid-template-columns:repeat(2, minmax(0,1fr));gap:30px">
      <div>
        <div class="label" style="padding-bottom:14px">Paper</div>
        <div class="rule-strong"></div>
        <div style="display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:16px;padding-top:16px">
          {sw('#F8F5EF','ground','#F8F5EF')}
          {sw('#FFFFFF','raised','#FFFFFF · bubbles only')}
          {sw('#1A1714','ink','#1A1714 · 16.4:1')}
          {sw('#C24A16','accent','#C24A16 · 4.5:1')}
        </div>
      </div>
      <div>
        <div class="label" style="padding-bottom:14px">Night</div>
        <div class="rule-strong"></div>
        <div style="display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:16px;padding-top:16px">
          {sw('#131211','ground','#131211')}
          {sw('#1B1917','raised','#1B1917')}
          {sw('#F2EEE7','ink','#F2EEE7 · 16.2:1')}
          {sw('#FF8A3D','accent','#FF8A3D · 8.0:1')}
        </div>
      </div>
    </div>

    <div>
      <div class="label" style="padding-bottom:10px">Type — a serif to name things, a sans to operate them</div>
      <div class="rule-strong"></div>
      {typ('t1','t1','Sessions','serif 34/40')}
      {typ('t2','t2','How hair tests work','serif 23/29')}
      {typ('body','body','A hair test looks for metabolites in the shaft.','sans 16/24')}
      {typ('sub','sub','Editing · vamp-assistant','sans 15')}
      {typ('label','label','Today','sans 10 · 1.4 tracking')}
      {typ('num','num','6.39','serif tabular')}
    </div>

    <div style="display:grid;grid-template-columns:1fr 1fr;gap:30px">
      <div>
        <div class="label" style="padding-bottom:10px">Rules, not boxes</div>
        <div class="rule-strong"></div>
        <div class="sub" style="padding-top:12px;line-height:22px">One hairline at 14% divides rows; the same line at 30% opens and closes a section. A fill appears only where you touch — the send button, a bubble, a chip — and glass only where something floats: the bar, a sheet, a popover.</div>
      </div>
      <div>
        <div class="label" style="padding-bottom:10px">The accent, spent once</div>
        <div class="rule-strong"></div>
        <div style="display:flex;align-items:center;gap:18px;padding-top:16px">
          <div style="width:38px;height:38px;border-radius:20px;background:{t['accent']};display:flex;align-items:center;justify-content:center">{ico('arrowup','#fff',18,1.6)}</div>
          <div style="display:flex;align-items:center;gap:8px"><div class="dot"></div><div class="fn">running</div></div>
          <div class="fn" style="color:{t['accent']}">Cancel</div>
        </div>
        <div class="sub" style="padding-top:14px;line-height:22px">Send, the live dot, one text action. Everything else is ink.</div>
      </div>
    </div>
  </div>
</div>
''' + TAIL

if __name__ == "__main__":
    open("Mac.dc.html","w").write(mac())
    open("Foundations.dc.html","w").write(foundations())
    print("ok")
